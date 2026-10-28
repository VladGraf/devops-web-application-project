# Configuration

No source file edits are needed. `.env` is optional; `.env.example` lists every
setting and its default. Use plain `KEY=number` lines, with no spaces, quotes or
shell expressions. Blank lines and full-line comments are allowed.

Settings are loaded in this order: defaults, saved `.state/settings.env`, `.env`,
then environment variables. Successful preflight saves the chosen settings before
starting services. Later commands use the same settings.

| Settings | Meaning |
| --- | --- |
| WEB_PORT, KIBANA_PORT | Browser ports; defaults 8088 and 5601 |
| ES_PORT | Local Elasticsearch API; default 19200 |
| NODE_PORT, API_PORT | k3d host ports; defaults 18080 and 16443 |
| SERVER_MEMORY_MB, WORKER_MEMORY_MB | Memory budget per K3s node for preflight checks |
| NGINX_MEMORY_MB, ES_MEMORY_MB, LOGSTASH_MEMORY_MB, KIBANA_MEMORY_MB | Docker memory limits |
| ES_HEAP_MB, LOGSTASH_HEAP_MB, KIBANA_HEAP_MB | JVM or Node heap size |
| NGINX_CPUS, ES_CPUS, LOGSTASH_CPUS, KIBANA_CPUS | Docker CPU limits, decimals allowed |
| APP_CPU_REQUEST_MILLICORES, APP_CPU_LIMIT_MILLICORES | App CPU request and limit |
| APP_MEMORY_REQUEST_MB, APP_MEMORY_LIMIT_MB | App memory request and limit |
| FLUENT_CPU_REQUEST_MILLICORES, FLUENT_CPU_LIMIT_MILLICORES | Collector CPU request and limit |
| FLUENT_MEMORY_REQUEST_MB, FLUENT_MEMORY_LIMIT_MB | Collector memory request and limit |

Memory values use MiB, despite the short `_MB` names. Ports must be different,
unprivileged ports from 1024 to 65535. All values must be positive.
Java heaps may use at most half their container limit. Kibana needs at least
256 MiB above its heap. Requests must not exceed limits.

Web, Kibana and Elasticsearch host ports and app/service limits can be changed
by running deployment again. k3d API/NodePort mappings are fixed
when the cluster is created. If those settings differ on an existing cluster,
the scripts stop and leave it unchanged. Existing nodes must also use the pinned
K3s image; automatic upgrades are not attempted. Keep its saved settings; cluster
replacement requires a separate decision and is never automatic.

Node memory flags are omitted because their generated meminfo bind mounts fail
from the temporary controller. Server/worker memory settings are preflight budgets.
The resource check estimates Docker and node memory needs plus overhead. It requires at least 2 GiB spare system RAM. First startup
also needs the project budget available. Repeated deployment allows for the
project's existing memory use. Larger limits can need more RAM than README's
minimum. Preflight does not reserve ports or RAM; another program can take them
after a check, in which case deployment reports the Docker error.

## Pinned compatibility baseline

| Component | Version |
| --- | --- |
| Controller Docker CLI | 27.5.1, Alpine 3.21 |
| Ansible Core | 2.18.4; Python dependencies pinned in controller/requirements.txt |
| k3d / K3s / kubectl | 5.8.3 / 1.31.7-k3s1 / 1.31.7 |
| App Python | 3.12.10, Alpine 3.21 |
| Nginx | 1.27.5, Alpine 3.21 |
| Elasticsearch / Logstash / Kibana | 8.17.3 for all three |
| Fluent Bit | 3.2.10 |

Image tags and Python packages have explicit versions. Alpine system packages
come from the pinned Alpine minor release's repositories. Images are not locked
to registry digests. This is a compatibility baseline for the lab, not a promise
of current production security support. Controller source/dependency changes
trigger a new controller build. App releases use content-based tags.

## Installer behavior

`deploy.sh` reads `/etc/os-release` without executing it. Supported releases map
to Docker's official APT suites: bookworm, trixie, jammy and noble.
A working host needs Docker Engine 27.5.1+, Compose 2.24.0+ and Buildx.
The installer uses available official package versions for a fresh host. Project
container/tool versions remain pinned as listed above.

Missing host commands are mapped to Debian/Ubuntu packages. APT first simulates
the requested install. Any removal or upgrade of an installed package is refused;
there is no automatic cleanup, replacement or broad system upgrade. This can
require an administrator to resolve dependencies on older systems.

Host changes require confirmation, or explicit `--yes`. The plan includes missing
packages, Docker repository setup, starting a new Engine, privileged Docker
access when needed, and a low `vm.max_map_count`. Kernel changes use only the
project's `/etc/sysctl.d/99-final-project.conf` and the running kernel value.
An existing file without the project marker is never overwritten.

New Engine installation stops if an old runtime package, Docker data directory,
or daemon configuration exists. An existing stopped or broken daemon is not
started or repaired automatically. Working engines and plugins are not reinstalled.
No automatic Docker group membership or socket permission changes are made.
Sudo access applies only to the approved invocation and its project commands.

`--check` never asks for consent, uses sudo, updates APT, downloads tools, writes
settings, builds images or starts deployment. Missing base commands or daemon
access can leave further checks pending; this produces a nonzero result.
The option wins over `--yes`. Check success is a host requirements check, not a
live application or cluster rollout test.
