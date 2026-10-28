# DevOps Web Application Project — Architecture

The project uses K3s running in Docker through k3d. The cluster is named
`final-project`. Its manifests and templates are in `k3s/`.

```text
Native Linux host -> local Docker Engine
  final-project_default network
    Nginx -> Docker DNS -> K3s server:30080 -> app:8000
    K3s: 1 server + 2 workers, plus the k3d load balancer
      Web app: 3 Pods on workers (normally 2 + 1)
      Fluent Bit: one collector per node
      logstash Service -> EndpointSlice -> current Logstash Docker IP:5000
    Logstash -> Elasticsearch -> Kibana
  Temporary controller: Bash, Ansible, Docker CLI, k3d, kubectl and Python
    project mount -> .state/settings.env and .state/kubeconfig
```

Host ports bind to loopback. Browser/API ports and resource limits come from the
shared project settings. Nginx resolves the server through Docker DNS; there is
no machine-specific address. Internal service ports stay fixed.

The Bash installer detects dependencies and shows proposed host changes. It uses
APT and Docker's signed repository only after approval. Read-only check mode ends
before host changes or deployment. Bash then checks resource ownership. Ansible creates
or checks the project cluster, applies configuration and updates the Logstash
EndpointSlice. No host Kubernetes configuration is mounted.

App images have content-based tags. Rolling updates keep the last healthy image
for rollback. Configuration is rendered without rewriting source manifests.

Elasticsearch data uses a named Docker volume. Fluent Bit uses a separate writable
state directory on each k3d node and reads logs through a read-only mount.
Stop/start keeps data. Cluster deletion removes node-local collector data.

Docker health checks cover Nginx and ELK. Kubernetes probes cover the app and
collector. Status checks HTTP responses and traces a new app log to Elasticsearch.
Project locks and ownership checks protect other containers and clusters.
