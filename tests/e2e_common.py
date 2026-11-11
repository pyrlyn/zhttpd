"""Process/socket fixtures shared by executable examples and configuration E2E."""
import contextlib
import os
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def running(command, port, cwd=None, env=None, startup_timeout=5):
    with tempfile.TemporaryFile(mode='w+') as log:
        process = subprocess.Popen([str(x) for x in command], cwd=cwd, env=env,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            for _ in range(int(startup_timeout / .025)):
                if process.poll() is not None:
                    raise AssertionError(f'process exited: {process.returncode}')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.025)
            else:
                raise AssertionError('listener did not start')
            yield process
        except BaseException:
            log.flush(); log.seek(0); print(log.read())
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
