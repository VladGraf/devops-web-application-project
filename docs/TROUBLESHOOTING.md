# Troubleshooting

## Docker or build fails
Check `docker info` and `docker compose version`.
Run `./deploy.sh --check` to see missing dependencies and access problems.
The first install and build need Internet access.
The controller rebuilds when its Dockerfile or pinned requirements change.
Only the controller installs Ansible, k3d, kubectl and Python packages.

## Ports or names are in use
Preflight reports the setting and conflicting port. Choose a different browser
or Elasticsearch port in `.env`; do not stop an unrelated service.
Defaults are 8088, 5601, 18080, 19200 and 16443.
The scripts refuse conflicting container, network and volume ownership.
Do not remove another project's resources to continue.

## Cluster check fails
The project expects `final-project` with 1 server, 2 workers and a load balancer
on the project Compose network. The k3d load balancer publishes the saved
NODE_PORT mapping to port 30080. API_PORT must also match the saved cluster
creation settings. Node memory settings are preflight resource budgets, not
fixed container memory limits.
An incompatible cluster is left unchanged. Inspect it before deciding what to do.
A stopped project should be resumed with `./start.sh`.

## Web app or logs fail
Run `./status.sh`. A nonzero result means a check failed.
Check `docker logs final-project-logstash` and
`docker logs final-project-elasticsearch`.
Check collectors:
```bash
./scripts/control.sh kubectl --context k3d-final-project -n final-project logs -l app=fluent-bit --tail=30
```
If Logstash was recreated, run deployment again to refresh its EndpointSlice.
Deployment keeps the current app image. The status check allows about a minute
for a marked request to appear in Elasticsearch.

## Rollback fails
Rollback needs a previous healthy release and its Docker image.
Do not prune project release images. A first deployment has no rollback target.
If an image was changed manually, inspect the Deployment and its release
annotations before making further changes.
Rollback applies the recorded previous image before waiting, even when the
current Deployment has failed. A retry restarts only an unhealthy `web-app`
whose Pod template did not change after applying resources.

## Operation is locked
Another command may be running. Wait for it to finish.
After a crash, verify that no project operation is running, then remove only the
empty `.state/operation.lock` directory with `rmdir .state/operation.lock`.

## Not enough memory
Stop the project with `./stop.sh` and free memory.
Run `./deploy.sh --check` before retrying. Increasing resource limits needs more RAM.

## Resource or host checks fail
Use a supported native Linux system with a local rootful Docker Engine.
Check Docker socket permissions, free memory and free disk space. Larger resource
limits need more RAM. The first run checks both project and Docker disk space.
If `vm.max_map_count` is too low, `./deploy.sh` offers a confirmed change to
262144. `--check` never changes it.

## Offline validation
On a computer that already has Python 3, PyYAML and jq, run:
```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```
Tests mock package installation, privileges, Docker, Kubernetes and HTTP.
They do not install packages, change host settings or deploy the project.

## Installer stops or confirmation fails
Run interactively to review and approve the displayed plan. For an approved
non-interactive run, use `./deploy.sh --yes` with root or usable `sudo -n` access.
Do not add `--yes` just to bypass an unresolved conflict; conflicts still stop it.

Old engine versions, conflicting runtime packages, old Docker data and APT plans
that would remove or upgrade installed packages require administrator review.
The installer does not delete or replace them. A failed repository download or
APT update may leave approved setup incomplete; rerun the check and read its error.
No automatic rollback removes packages or repository files.
Matching project repository files can be reused after an interruption. Changed
source files or a signing key that differs from Docker's official key still
require administrator review; the installer does not overwrite them.

Sudo Docker access lasts only for the approved installer run. Later project
commands can be run with sudo if needed. Configure permanent Docker permissions
separately if desired. The installer never makes the socket world-writable.

## Deployment failed
The terminal prints the exact log file under `.state/logs/`.
Each attempt has a UTC timestamp and a unique name. Earlier logs are kept.
Find the failed `TASK [...]`, its `stdout`, `stderr` and `rc`, and the final
`Deployment exit_code`. Stage markers show where deployment stopped.
Logs include installer and build output before Ansible starts.

Output is redacted before it reaches the terminal or disk. Logs use mode 600;
the log directory uses mode 700. Redaction covers known environment secret values,
credential fields, URL credentials, private-key blocks and common token formats.
For future Ansible tasks that handle secrets, use `no_log: true`; arbitrary
unlabelled secrets cannot always be identified. No raw log is saved.

Failure does not run cleanup or stop the healthy Docker services. Cluster
validation stays strict. Read the log before deciding on a fix or retry.
If installation failed before cluster creation, `./destroy.sh` can still remove
project-owned Compose services and data after confirmation. An existing partial
or incompatible cluster still blocks deletion and needs inspection.
Base OS `awk` and coreutils are needed to create safe logs. Check mode bypasses
log creation and keeps its read-only behavior.

## Deployment appears to wait silently
The logger enables mawk interactive input so lines reach the terminal and log
while deployment is running. Approval still needs a typed answer; after 120 seconds
without an answer, installation is cancelled. No answer ever means approval.

Docker read-only checks have a 30-second deadline and report timeout exit codes.
Signing-key downloads allow 10 seconds to connect and 60 seconds in total.
APT network requests allow 30 seconds and two retries. Package installation is
not killed by an overall timer, so dpkg transactions can finish safely.

For a different deadline, set `FINAL_PROJECT_CONFIRM_TIMEOUT_SECONDS` (1–600) or
`FINAL_PROJECT_DOCKER_CHECK_TIMEOUT_SECONDS` (1–120) in the environment, not `.env`.
These fixes apply to new invocations; an already waiting process is left untouched.
