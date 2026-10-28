# DevOps Web Application Project

A local learning project: a Python web app on K3s running in Docker through k3d,
with Nginx and ELK logs.
K3s manifests are in `k3s/`. The cluster name is `final-project`.

## Supported computers
- Debian 12/13 or Ubuntu 22.04/24.04 LTS, using systemd and cgroup v2
- x86_64 or ARM64; at least 4 logical CPUs and 16 GiB RAM
- About 11 GiB available RAM on first startup
- At least 25 GiB free on the project and Docker data filesystems
- Bash 4.3+, Git, Internet access for installation, and root or sudo access if needed

Use native Linux with a local, rootful Docker Engine. Docker Desktop, remote
Docker, rootless Docker and user namespace remapping are outside this scope.

## Run
```bash
git clone https://github.com/VladGraf/devops-web-application-project.git
cd devops-web-application-project
./deploy.sh
```
The installer checks the OS, resources, ports, dependencies and Docker access.
It shows a plan and asks before installing packages or changing host settings.
Missing system tools use APT. Docker Engine, Compose and Buildx use Docker's
official signed repository. Working software is kept.

Ansible, k3d, kubectl, Python and jq run in the project controller container.
The first deployment can take 15–45 minutes.
Web: http://localhost:8088. Kibana: http://localhost:5601.
App endpoints: `/`, `/healthz`, `/readyz`, `/api/status` and `/api/metrics`
at the Web URL. Nginx health: http://localhost:8088/nginx-health.

## Check or approve installation
```bash
./deploy.sh --check       # Read-only checks; never installs or deploys
sudo ./deploy.sh --yes    # Unattended deployment after sudo authentication
```
Check mode returns 0 when ready and nonzero when something needs attention.
`--check --yes` still only checks. It does not ask for sudo or create project state.
For unattended evaluation on Debian 13, use `sudo ./deploy.sh --yes` after cloning.
Sudo may ask for your password before starting. The deployment then runs as root
and does not ask for installation confirmation. From a root shell, use
`./deploy.sh --yes`. For a job with no terminal, run as root or use
`sudo -n ./deploy.sh --yes` with administrator-configured passwordless sudo.
Plain `./deploy.sh --yes` also works with sufficient existing permissions; if it
needs sudo, sudo must work without prompting throughout the run. A cached sudo
session can expire during a long deployment. No sudo policy is changed.
Normal `./deploy.sh` keeps confirmation; declining leaves the host unchanged.

The installer can use sudo for Docker during the approved run. It does not change
your group membership or loosen socket permissions. Later commands may need sudo if your user still
has no Docker access. A low `vm.max_map_count` can be raised with approval.
Existing runtimes, old Docker data and package conflicts are left for manual
review. Existing engines are never replaced or restarted automatically.

Real deployment attempts keep separate redacted logs in `.state/logs/`.
They include Ansible task results, stdout, stderr and exit codes. Failures print
the log path. Previous logs stay in place. Prompts and progress stream immediately.
Unanswered confirmation cancels after 120 seconds; Docker checks allow 30 seconds.
`--check` creates no log or state.

## Settings and commands
Ports and resource limits work with defaults. Optionally copy `.env.example` to
`.env` and edit its numbers, or use `WEB_PORT=8090 ./deploy.sh`.
See [configuration](docs/CONFIGURATION.md).

```bash
./status.sh       # Check services, HTTP and delivery of a new app log
./update.sh       # Deploy a new content-tagged v2 release
./rollback.sh     # Return to the previous healthy release
./stop.sh         # Stop and keep data
./start.sh        # Start and check readiness
./destroy.sh      # Confirm deletion of project services, cluster and ELK data
```
If you deployed with sudo, use `sudo ./status.sh`, `sudo ./update.sh`,
`sudo ./rollback.sh`, `sudo ./stop.sh`, `sudo ./start.sh` and `sudo ./destroy.sh`
consistently, because saved settings may be owned by root.
The URLs above use default ports; configured `WEB_PORT` and `KIBANA_PORT` replace
8088 and 5601 when changed.

Repeated deployment keeps the working release. The cluster has 1 server and
2 workers, with 3 app Pods. Settings and credentials stay in `.state/`;
Elasticsearch uses a Docker volume. Do not commit `.state/` or `.env`.
The host Kubernetes configuration is never used.

Deployment automatically prepares the Kibana Data View `DevOps Project Logs`
for `final-project-logs-*`, using `@timestamp`. Open Discover and select it to read
logs; no manual Data View setup is needed.
This is a local lab without ELK login. Host ports bind to loopback. The controller
has Docker socket access; run trusted code only. No Helm, Makefile, Prometheus,
Grafana or Vagrant is used. See [troubleshooting](docs/TROUBLESHOOTING.md).
