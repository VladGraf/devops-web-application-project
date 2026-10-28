import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

VERSION = os.environ.get('APP_VERSION', 'v1')
START = time.monotonic()

def memory():
    # cgroup v2 memory is container memory, not host RAM.
    try:
        used = int(Path('/sys/fs/cgroup/memory.current').read_text().strip())
        limit = Path('/sys/fs/cgroup/memory.max').read_text().strip()
        return {'used_mb': round(used / 1048576, 1), 'limit_mb': None if limit == 'max' else round(int(limit) / 1048576, 1)}
    except (OSError, ValueError):
        return {'used_mb': None, 'limit_mb': None}

def cpu():
    try:
        values = Path('/sys/fs/cgroup/cpu.stat').read_text().splitlines()
        return {line.split()[0]: int(line.split()[1]) for line in values if line.startswith('usage_usec ')}.get('usage_usec')
    except (OSError, ValueError):
        return None

def network():
    try:
        rows = Path('/proc/net/dev').read_text().splitlines()[2:]
        rx = tx = 0
        for line in rows:
            name, data = line.split(':', 1)
            if name.strip() != 'lo':
                values = data.split()
                rx += int(values[0]); tx += int(values[8])
        return {'received_bytes': rx, 'sent_bytes': tx}
    except (OSError, ValueError, IndexError):
        return {'received_bytes': None, 'sent_bytes': None}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path in ('/healthz', '/readyz'):
            return self.send(200, 'text/plain', b'OK')
        if path in ('/api/status', '/api/metrics'):
            data = {'service': 'web-app', 'status': 'healthy', 'version': VERSION,
                    'pod': os.environ.get('HOSTNAME', 'local'), 'uptime_seconds': round(time.monotonic()-START),
                    'memory': memory(), 'cpu_usage_usec': cpu(), 'network': network()}
            return self.send(200, 'application/json', json.dumps(data).encode())
        if path != '/':
            return self.send(404, 'text/plain', b'Not found')
        page = Path('/app/index.html').read_text().replace('{{VERSION}}', VERSION).replace('{{POD}}', os.environ.get('HOSTNAME', 'local'))
        self.send(200, 'text/html; charset=utf-8', page.encode())

    def send(self, code, content_type, body):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(json.dumps({'event': 'http_request', 'path': self.path, 'message': format % args, 'version': VERSION}), flush=True)

if __name__ == '__main__':
    print(json.dumps({'event': 'started', 'version': VERSION}), flush=True)
    ThreadingHTTPServer(('0.0.0.0', 8000), Handler).serve_forever()
