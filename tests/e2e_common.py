"""Process/socket fixtures shared by executable examples and configuration E2E."""
import contextlib
import fcntl
import os
import random
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Below the ephemeral ranges of Linux (32768+) and macOS/BSD (49152+): the
# kernel never gives these to a bind(0) helper or an outgoing connection, so a
# port stays free from free_port() until the server binds it, however late.
_candidates = random.sample(range(20000, 32768), 12768)
_claims = None


def free_port():
    """Reserve a TCP+UDP port; concurrent test processes never get the same one."""
    global _claims
    if _claims is None:
        # One byte per port, locked until this process exits.
        _claims = os.open(Path(tempfile.gettempdir())/f'zhttpd-e2e-ports-{os.getuid()}',
                          os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    while _candidates:
        port = _candidates.pop()
        try:
            fcntl.lockf(_claims, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, port)
            with socket.socket() as tcp, socket.socket(type=socket.SOCK_DGRAM) as udp:
                tcp.bind(('', port)); udp.bind(('', port))
        except OSError:
            continue
        return port
    raise AssertionError('no free port')


def listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.1):
            return True
    except OSError:
        return False


@contextlib.contextmanager
def running(command, port, cwd=None, env=None, startup_timeout=5, log_path=None, pid_file=None):
    """Run a server until the block ends. The master writes pid_file after it
    listens, so pass it when the test reads that file."""
    # A listener that is already there is not the process started below.
    assert not listening(port), f'port {port} is already in use'
    def started():
        if not listening(port): return False
        if pid_file is None: return True
        try: return int(Path(pid_file).read_text()) == process.pid
        except (OSError, ValueError): return False
    with (open(log_path, 'w+') if log_path else tempfile.TemporaryFile(mode='w+')) as log:
        process = subprocess.Popen([str(x) for x in command], cwd=cwd, env=env,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            for _ in range(int(startup_timeout / .025)):
                if process.poll() is not None:
                    raise AssertionError(f'process exited: {process.returncode}')
                if started(): break
                time.sleep(.025)
            else:
                raise AssertionError('listener or pid file did not appear')
            yield process
        except BaseException:
            log.flush(); log.seek(0); print(log.read(), file=sys.stderr)
            raise
        finally:
            # Always target only the process group created by this fixture.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
