#!/usr/bin/env bash
set -euo pipefail
# Kibana distributions can use either bundled Node layout.
for node_binary in /usr/share/kibana/node/bin/node /usr/share/kibana/node/glibc-217/bin/node; do
  if [[ -x "$node_binary" ]]; then
    exec "$node_binary" -e "fetch('http://127.0.0.1:5601/api/status').then(async r=>{const d=await r.json();process.exit(r.ok && d.status.overall.level==='available'?0:1)}).catch(()=>process.exit(1))"
  fi
done
echo 'Bundled Kibana Node binary was not found' >&2
exit 1
