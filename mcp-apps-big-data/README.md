# MCP Apps Big Data Demo
This scenario demonstrates using MCP Apps to orchestrate, modify and upgrade
a complex Big Data workload.

Key benefits:

- Efficiently orchestrate complicated multi-component applications on top of
  multiple clouds
- Improved time to market through ability to quickly roll out changes

## Preparation and deploy Steps
Below are the steps needed to setup the demo environment.

### Initial prep with GCP, helm and Twitter API

1. Create a Google Cloud Platform(GCP) account
1. Create a new project in GCP. Throughout the steps we will use mcp-apps-5
1. Setup the gcloud cli by following one of the
   [gcloud cli Quickstarts](https://cloud.google.com/sdk/docs/quickstarts)
1. Set gcloud to use the created project

   ```bash
   gcloud config set project mcp-apps-5
   ```

1. Setup firewall rules in newly created project to allow all ingress

   ```bash
   gcloud beta compute firewall-rules create allow-all --direction=INGRESS \
      --priority=1000 --network=default --allow=all --source-ranges=0.0.0.0/0
   ```

1. Install helm-client on your laptop.
   See [Install Guide](https://github.com/kubernetes/helm/blob/master/docs/install.md).

1. Install helm-apply plugin for helm

   ```bash
   git clone https://github.com/Mirantis/k8s-apps/
   cd k8s-apps
   helm plugin install helm-apply
   ```

1. Go to apps.twitter.com and "Create a New App"
1. Retrieve the following infomration from the newly created Twitter App:
   * Consumer Key (API Key)
   * Consumer Secret (API Secret)
   * Access Token
   * Access Token Secret

1. Create an account at [Docker Hub](https://hub.docker.com/)

### Deploy K8s clusters on GCP

1. First clone the mirantis-demos repistory

   ```bash
   git clone https://github.com/samos123/mirantis-demos.git
   cd mirantis-demos/mcp-apps-big-data
   ```
1. Deploy K8s clusters on GCP

   ```bash
    ./deploy-k8s.sh
   ```

1. Setup kubectl to utilize frontend k8s cluster

   ```bash
   # Download kube config and set it as current context in ~/.kube/config
   # substitute mcp-apps-5 for actual project id that you used
   gcloud container clusters get-credentials frontend --zone us-west1-c --project mcp-apps-5
   # Verify that following command succeeds and shows 1 node
   kubectl get nodes
   ```

### Deploy MCP Apps (Spinnaker, Gerrit, Jenkins)

1. Add the Mirantis helm repository that contains all the charts used in this demo

   ```bash
   helm repo add mirantisworkloads https://mirantisworkloads.storage.googleapis.com
   ```

1. Modify the Twitter API credentials

   ```bash
   cp twitter-api.yaml.example twitter-api.yaml
   # modify the values that start with CHANGETO
   vim twitter-api.yaml
   ```

1. Modify the Docker Hub credentials

   ```bash
   cp docker-hub.yaml.example docker-hub.yaml
   # modify the values starting with CHANGETO
   vim docker-hub.yaml
   ```


1. Deploy Spinnaker, Jenkins and Gerrit using helm

   ```bash
   helm install -f values.yaml -f twitter-api.yaml -f gke-clusters.yaml \
      -f docker-hub.yaml -f external-ips.yaml mirantisworkloads/rollout \
      --timeout 900
   ```

## Demo time

Now we can demo making a change to the web UI component that visualizes
Twitter data.

