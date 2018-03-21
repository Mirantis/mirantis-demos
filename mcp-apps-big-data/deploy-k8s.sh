#!/bin/bash

set -eou pipefail

#################### Setup debug and colors

COLOR_GRAY='\033[0;37m'
COLOR_BLUE='\033[0;34m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

function finish() {
    echo -e -n $COLOR_RESET
}
trap finish EXIT

echo -e -n $COLOR_GRAY

DEBUG=${DEBUG:-no}
if [ "yes" == "$DEBUG" ]; then
    set -x
fi

#################### Main section

# We shouldn't use OAuth2, just use k8s own auth
export CLOUDSDK_CONTAINER_USE_CLIENT_CERTIFICATE=True

function main() {
    if [ "$#" -ne "1" ]; then
        echo "ERROR: (demo-gke.sh) Too few arguments"
        echo "Usage: demo-gke.sh < up | down >"
        exit 1
    fi

    # common configs
    values_file="gke-clusters.yaml"
    ips_file="external-ips.yaml"
    cluster_size=1
    disk_size=30
    cluster_region=us-west1-c

    # frontend cluster configs
    frontend_cluster_name=frontend
    frontend_cluster_flavor=n1-standard-4

    # backend cluster configs
    backend_cluster_name=backend
    backend_cluster_flavor=n1-standard-8


    if [ "up" == "$1" ]; then
        # create "frontend" and "backend" clusters
        gke_cluster_create $frontend_cluster_name $cluster_region $disk_size $frontend_cluster_flavor $cluster_size
        gke_cluster_create $backend_cluster_name $cluster_region $disk_size $backend_cluster_flavor $cluster_size

        # wait until clusters are alive and setup
        gke_cluster_wait_alive $frontend_cluster_name $cluster_region
        gke_cluster_wait_alive $backend_cluster_name $cluster_region

        # Deploy tiller
        helm_init $frontend_cluster_name $cluster_region
        helm_init $backend_cluster_name $cluster_region

        # create gke-clusters.yaml to use during rollout chart installation
        clusters_values_file_create $values_file $ips_file $frontend_cluster_name $backend_cluster_name $cluster_region

    elif [ "down" == "$1" ]; then
        gke_cluster_delete $frontend_cluster_name $cluster_region
        gke_cluster_delete $backend_cluster_name $cluster_region

        gke_cluster_wait_deleted $frontend_cluster_name $cluster_region
        gke_cluster_wait_deleted $backend_cluster_name $cluster_region

    else
        log "Unsupported command '$1'"
        exit 1
    fi
}

function clusters_values_file_create {
    values_file="$1"
    ips_file="$2"
    frontend_cluster_name="$3"
    backend_cluster_name="$4"
    cluster_region="$5"

    printf "kubeConfigs:\n  frontend: |\n" > $values_file
    printf "helmApplyConfig:\n  clusters:\n    frontend:\n      externalIP: " > $ips_file
    gke_cluster_configs $frontend_cluster_name $cluster_region $values_file $ips_file
    printf "\n  backend: |\n" >> $values_file
    printf "\n    backend:\n      externalIP: " >> $ips_file
    gke_cluster_configs $backend_cluster_name $cluster_region $values_file $ips_file
}

#################### Logging utils

function log() {
    set +x
    echo -e "$COLOR_BLUE[$(date +"%F %T")] gke-demo $COLOR_RED|$COLOR_RESET" $@$COLOR_GRAY
    if [ "yes" == "$DEBUG" ] ; then
        set -x
    fi
}

function cluster_log_name() {
    echo "'$name' ($zone)"
}

#################### Commands aliases

function gke() {
    gcloud container clusters $@
}

#################### Cluster ops

function gke_cluster_exists() {
    name="$1"
    zone="$2"

    if gke describe $name --zone $zone 2>/dev/null | grep -q "^name: $name\$" ; then
        return 0
    else
        return 1
    fi
}

function gke_cluster_create() {
    name="$1"
    zone="$2"
    disk_size="$3"
    machine_type="$4"
    num_nodes="$5"

    if gke_cluster_exists $name $zone ; then
        log "Cluster $(cluster_log_name) already exists, run cleanup first to re-create"
    else
        log "Creating cluster $(cluster_log_name)"

        gke create \
            $name \
            --zone $zone \
            --disk-size $disk_size \
            --machine-type $machine_type \
            --num-nodes $num_nodes \
            --no-enable-cloud-monitoring \
            --no-enable-cloud-logging \
            --enable-legacy-authorization \
            --async
    fi
}

function gke_cluster_running() {
    name="$1"
    zone="$2"

    if gke describe $name --zone $zone | grep -q "^status: RUNNING\$" ; then
        log "Cluster $(cluster_log_name) is RUNNING"
        return 0
    else
        log "Cluster $(cluster_log_name) isn't RUNNING"
        return 1
    fi
}

function gke_cluster_wait_alive() {
    name="$1"
    zone="$2"

    retries=0
    # retry for 15 minutes
    until [ $retries -ge 90 ]
    do
        if gke_cluster_running $name $zone ; then
            break
        fi
        sleep 10
        retries=$[$retries+1]
    done
}

function gke_cluster_wait_deleted() {
    name="$1"
    zone="$2"

    retries=0
    # retry for 15 minutes
    until [ $retries -ge 90 ]
    do
        if ! gke_cluster_exists $name $zone ; then
            break
        fi
        log "Cluster $(cluster_log_name) is still not deleted"
        sleep 10
        retries=$[$retries+1]
    done
}

function gke_cluster_delete() {
    name="$1"
    zone="$2"

    if ! gke_cluster_exists $name $zone ; then
        log "Cluster $(cluster_log_name) doesn't exist"
    else
        log "Deleting cluster $(cluster_log_name)"

        if gke delete $name --zone $zone --quiet --async; then
            log "Cluster $(cluster_log_name) deleted successfully (async)"
        else
            log "Cluster $(cluster_log_name) deletion failed, try to re-run cleanup"
            exit 1
        fi
    fi
}

#################### Kubeconfig ops

function kcfg_user_of_context() {
    name="$1"
    kubectl config view -o=jsonpath="{.contexts[?(@.name==\"$name\")].context.user}"
}

function kcfg_cluster_of_context() {
    name="$1"
    kubectl config view -o=jsonpath="{.contexts[?(@.name==\"$name\")].context.cluster}"
}

function gke_cluster_configs() {
    name="$1"
    zone="$2"
    values_file="$3"
    ips_file="$4"

    project="$(gcloud config get-value project 2>/dev/null)"

    cfg_file="$(mktemp)"
    if KUBECONFIG=${cfg_file} gke get-credentials $1 --zone $2 2>/dev/null ; then
        kcfg_name="gke_${project}_${zone}_${name}"
        context=$kcfg_name
        user="$(KUBECONFIG=${cfg_file} kcfg_user_of_context $context)"
        cluster="$(KUBECONFIG=${cfg_file} kcfg_cluster_of_context $context)"

        if [[ -z "$user" || -z "$cluster" ]]; then
            exit 1
        fi

        env KUBECONFIG=${cfg_file} kubectl config set-context $name --cluster=$cluster --user=$user &>/dev/null
        env KUBECONFIG=${cfg_file} kubectl config use-context $name &>/dev/null
        env KUBECONFIG=${cfg_file} kubectl config delete-context $kcfg_name &>/dev/null

        cat $cfg_file | sed "s/^/    /" >> $values_file
        KUBECONFIG=${cfg_file} kubectl get nodes -o template --template='{{range.items}}{{range.status.addresses}}{{if eq .type "ExternalIP"}}{{.address}}{{end}}{{end}}{{end}}' >> $ips_file

    else
        exit 1
    fi
}

#################### Helm utils

function helm_alive() {
    name="$1"
    config="$2"

    if ! KUBECONFIG=${config} kubectl -n kube-system describe deploy tiller-deploy 2>/dev/null | grep -q "1 desired"; then
        log "Can't find Tiller deployment in cluster $name"
        return 1
    fi

    if ! KUBECONFIG=${config} helm --tiller-namespace kube-system ls --all 1>/dev/null 2>/dev/null ; then
        log "Helm in cluster $name seems not really alive"
        return 1
    fi

    log "Helm in cluster $name seems alive"
    return 0
}

function helm_init() {
    name="$1"
    zone="$2"

    project="$(gcloud config get-value project 2>/dev/null)"

    cfg_file="$(mktemp)"
    if KUBECONFIG=${cfg_file} gke get-credentials $1 --zone $2 2>/dev/null ; then
        KUBECONFIG=${cfg_file} kubectl -n kube-system create sa tiller 2>/dev/null
        KUBECONFIG=${cfg_file} kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller 2>/dev/null

        if ! KUBECONFIG=${cfg_file} helm init --tiller-namespace kube-system --service-account tiller 2>/dev/null ; then
            log "Helm init failed in cluster $name"
            exit 1
        fi

        log "Waiting 10 seconds for Tiller to start"
        sleep 10

        retries=0
        # retry for 5 minutes
        until [ $retries -ge 60 ]
        do
            if helm_alive $name $cfg_file ; then
                break
            fi
            sleep 5
            retries=$[$retries+1]
        done

        # recheck
        if ! helm_alive $name $cfg_file ; then
            log "Helm isn't alive 5 minutes after running helm init, fail"
            exit 1
        else
            log "Helm in cluster $name successfully initialized"
        fi
    else
        log "Can't get credentials for cluster $(cluster_log_name)"
        exit 1
    fi
}

#################### End

main $@
log "deploy-k8s.sh $@ successfully finished"
