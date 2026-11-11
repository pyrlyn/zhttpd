#!/usr/bin/env python3
"""Three real Raft nodes: quorum, failover, snapshots, restart and zhttpd exports."""
import contextlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from e2e_common import free_port, running

SERVER = Path(sys.argv[1]).resolve()
AGENT = Path(sys.argv[2]).resolve()
TOKEN = 'test-only-raft-secret-with-at-least-32-characters'
CLUSTER = 'e2e-cluster'


def eventually(check, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError(label)


def api(port, path='/v1/status', method='GET', data=None, token=TOKEN):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=6)
    try:
        conn.request(method, path, json.dumps(data) if data is not None else None,
                     {'Authorization': 'Bearer ' + token, 'X-Zhttpd-Cluster': CLUSTER,
                      'Content-Type': 'application/json'})
        response = conn.getresponse()
        return response.status, json.loads(response.read())
    finally:
        conn.close()


def server_request(port, path='/'):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        conn.request('GET', path)
        response = conn.getresponse()
        return response.status, response.read().decode()
    finally:
        conn.close()


class Agent:
    def __init__(self, config, port):
        self.config, self.port = config, port
        self.process = None
        self.log = tempfile.TemporaryFile(mode='w+')

    def start(self):
        self.process = subprocess.Popen([AGENT, '-config', self.config], stdout=self.log,
                                        stderr=self.log, start_new_session=True)
        def ready():
            if self.process.poll() is not None:
                raise AssertionError('Raft agent exited during startup')
            try:
                return api(self.port)[0] == 200
            except OSError:
                return False
        eventually(ready, 'Raft API did not start')

    def stop(self, kill=False):
        if self.process is not None and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL if kill else signal.SIGTERM)
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.process = None

    def status(self):
        if self.process is None:
            return {}
        try:
            return api(self.port)[1]
        except OSError:
            return {}

    def dump(self):
        self.log.flush(); self.log.seek(0); print(self.log.read())


def main():
    with tempfile.TemporaryDirectory(prefix='zhttpd-raft-') as directory:
        root = Path(directory)
        token = root / 'token'; token.write_text(TOKEN); token.chmod(0o600)
        ids = 'abcd'
        used = set()
        def port():
            while True:
                candidate = free_port()
                if candidate not in used:
                    used.add(candidate)
                    return candidate
        ports = {node: (port(), port(), port()) for node in ids}
        peers = [dict(id=node, raft_address=f'127.0.0.1:{ports[node][0]}',
                      api_address=f'127.0.0.1:{ports[node][1]}') for node in ids]
        agents = {}
        servers = contextlib.ExitStack()
        held = []
        def server_config(node, response):
            origins = ', '.join(json.dumps(f'http://127.0.0.1:{ports[n][2]}') for n in 'abc')
            return f'''[server]
compatibility = "self"
[http]
listen = "127.0.0.1:{ports[node][2]}"
response = "{response}"
[load_balancer]
enabled = true
node_id = "{node}"
backend = "{root / node / 'view'}"
publish_backend = "{root / node / 'inbox'}"
node_ids = ["a", "b", "c"]
node_urls = [{origins}]
max_connections = {8 if node == 'a' else 64}
memory_limit_mb = 4096
cpu_capacity = 4
interval_ms = 100
ttl_ms = 5000
'''
        def leader():
            candidates = [node for node, agent in agents.items()
                          if agent.status().get('role') == 'Leader']
            return candidates[0] if len(candidates) == 1 else None
        def state():
            who = leader()
            if who is None:
                return None
            status, value = api(agents[who].port, '/v1/state')
            return value if status == 200 else None
        try:
            for node in ids:
                local = root / node; local.mkdir()
                server_file = local / 'server.toml'
                if node != 'd':
                    server_file.write_text(server_config(node, node))
                cfg = dict(id=node, cluster_id=CLUSTER,
                    raft_address=peers[ids.index(node)]['raft_address'],
                    api_address=peers[ids.index(node)]['api_address'],
                    data_dir=str(local / 'data'), metrics_inbox=str(local / 'inbox'),
                    metrics_view=str(local / 'view'), config_output=str(server_file),
                    token_file=str(token), peers=peers[:3], bootstrap=node != 'd',
                    insecure_loopback=True, interval_ms=200, metrics_ttl_ms=5000)
                config = local / 'raft.json'; config.write_text(json.dumps(cfg))
                agents[node] = Agent(config, ports[node][1])
            for node in 'abc':
                agents[node].start()
                servers.enter_context(running([SERVER, '-c', root / node / 'server.toml'], ports[node][2]))
            who = eventually(leader, 'no leader elected')
            assert api(agents[who].port, token='wrong')[0] == 401
            follower = next(n for n in 'abc' if n != who)
            assert api(agents[follower].port, '/v1/state')[0] == 409
            eventually(lambda: (s := state()) and all(s['metrics'].get(n, {}).get('records') for n in 'abc'),
                       'metrics were not replicated')
            held = [socket.create_connection(('127.0.0.1', ports['a'][2]), timeout=3) for _ in range(12)]
            eventually(lambda: server_request(ports['a'][2])[0] == 307, 'committed metrics did not drive balancing')
            for sock in held:
                sock.close()
            held.clear()
            # Commit complete per-node server configuration; native watcher reloads it.
            who = eventually(leader, 'no config leader')
            update = dict(node='b', expected_revision=0, toml=server_config('b', 'committed-one'))
            assert api(agents[who].port, '/v1/config', 'PUT', update)[0] == 200
            eventually(lambda: server_request(ports['b'][2], '/?__zhttpd_lb=1') == (200, 'committed-one'),
                       'committed configuration was not activated')
            assert api(agents[who].port, '/v1/config', 'PUT', update)[0] == 409
            assert api(agents[who].port, '/v1/snapshot', 'POST')[0] == 200
            assert list((root / who / 'data' / 'snapshots').glob('*/state.bin'))
            # Hard-kill the leader, retaining disk state. The other two form a quorum.
            first_dead = who
            agents[first_dead].stop(kill=True)
            new_leader = eventually(leader, 'no failover leader')
            assert new_leader != first_dead
            update = dict(node='c', expected_revision=0, toml=server_config('c', 'after-failover'))
            assert api(agents[new_leader].port, '/v1/config', 'PUT', update)[0] == 200
            # c's exporter may be stopped with the old leader; verify committed state now.
            assert state()['documents']['c']['toml'] == update['toml']
            second_dead = next(n for n in 'abc' if n not in (first_dead, new_leader))
            agents[second_dead].stop(kill=True)
            eventually(lambda: agents[new_leader].status().get('role') != 'Leader',
                       'minority retained leadership')
            forbidden = dict(node='b', expected_revision=1, toml=server_config('b', 'must-not-commit'))
            assert api(agents[new_leader].port, '/v1/config', 'PUT', forbidden)[0] != 200
            held = [socket.create_connection(('127.0.0.1', ports['a'][2]), timeout=3) for _ in range(12)]
            expired = time.monotonic() + 5.2
            eventually(lambda: time.monotonic() >= expired and server_request(ports['a'][2])[0] == 200,
                       'metrics remained usable without quorum')
            for sock in held:
                sock.close()
            held.clear()
            # Recovery uses the existing log/snapshot, never bootstraps a new cluster.
            agents[first_dead].start(); agents[second_dead].start()
            eventually(leader, 'cluster did not recover')
            eventually(lambda: (s := state()) and s['documents'].get('b', {}).get('revision') == 1
                       and s['documents'].get('c', {}).get('toml') == update['toml'], 'committed state lost')
            eventually(lambda: server_request(ports['c'][2], '/?__zhttpd_lb=1') == (200, 'after-failover'),
                       'restarted node did not export committed config')
            # Add an unbootstrapped node through Raft, then remove it through Raft.
            agents['d'].start()
            who = eventually(leader, 'no membership leader')
            assert api(agents[who].port, '/v1/members', 'POST', peers[3])[0] == 200
            eventually(lambda: len(agents[who].status().get('members', [])) == 4
                       and agents['d'].status().get('applied_index', 0) >= state()['index'] - 10,
                       'new voter did not catch up')
            assert api(agents[who].port, '/v1/members/d', 'DELETE')[0] == 200
            eventually(lambda: len(agents[who].status().get('members', [])) == 3, 'member removal failed')
            agents['d'].stop()
            # Simultaneous full restart proves recovery beyond in-memory state.
            for node in 'abc':
                agents[node].stop(kill=True)
            for node in 'abc':
                agents[node].start()
            eventually(lambda: (s := state()) and s['documents'].get('b', {}).get('revision') == 1
                       and s['documents'].get('c', {}).get('revision') == 1, 'full restart lost configuration')
            print('PASS: Raft quorum, 307 metrics, config CAS/reload, snapshot, leader death, minority rejection, recovery and voter changes')
        except BaseException:
            for node, agent in agents.items():
                print('Raft log:', node); agent.dump()
            raise
        finally:
            for sock in held:
                sock.close()
            servers.close()
            for agent in agents.values():
                agent.stop(); agent.log.close()


if __name__ == '__main__':
    main()
