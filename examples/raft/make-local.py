#!/usr/bin/env python3
"""Create an isolated three-node loopback demo; never overwrite Raft state."""
import json
import os
from pathlib import Path
import secrets
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else '.run/raft-demo').resolve()
if root.exists():
    raise SystemExit(f'{root} already exists; reuse it to restart the cluster or choose a new directory')
root.mkdir(parents=True, mode=0o700)
(root / 'token').write_text(secrets.token_hex(32))
os.chmod(root / 'token', 0o600)
peers = [dict(id=node, raft_address=f'127.0.0.1:{9301 + i}', api_address=f'127.0.0.1:{9401 + i}')
         for i, node in enumerate(('node-a', 'node-b', 'node-c'))]
urls = [f'http://127.0.0.1:{9501+i}' for i in range(3)]
for i, peer in enumerate(peers):
    local = root / peer['id']; local.mkdir(mode=0o700)
    config = dict(peer, cluster_id='local-demo', data_dir='data', metrics_inbox='inbox',
                  metrics_view='view', config_output='server.toml', token_file='../token',
                  peers=peers, bootstrap=True, insecure_loopback=True,
                  interval_ms=1000, metrics_ttl_ms=5000)
    (local / 'raft.json').write_text(json.dumps(config, indent=2) + '\n')
    (local / 'server.toml').write_text(f'''[server]
compatibility = "self"
[http]
listen = "127.0.0.1:{9501+i}"
response = "hello from {peer['id']}"
[load_balancer]
enabled = true
node_id = "{peer['id']}"
backend = "view"
publish_backend = "inbox"
node_ids = {json.dumps([p['id'] for p in peers])}
node_urls = {json.dumps(urls)}
max_connections = 100
memory_limit_mb = 512
cpu_capacity = 1
interval_ms = 1000
ttl_ms = 5000
''')
    print(f'zig-out/bin/zhttpd-raft -config {local / "raft.json"}')
    print(f'zig-out/bin/zhttpd -c {local / "server.toml"}')
print(f'Credentials: {root / "token"}; start each command in its own terminal or process supervisor.')
