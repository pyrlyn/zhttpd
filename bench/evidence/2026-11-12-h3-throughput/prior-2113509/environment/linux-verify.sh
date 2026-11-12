set -eu
root=/home/listepo.guest/zhttpd-perf-h3-throughput
host=/Users/listepo/apps/_worktrees/zhttpd-perf-h3-throughput
cd "$root/candidate"
cp "$host/build.zig" .
cp "$host/src/server/"{multiplex.c,multiplex.zig,worker.zig} src/server/
cp "$host/tests/"{h2-keyupdate.c,protocols.py,quic_io.c} tests/
export PATH=/home/listepo.guest/zhttpd-perf-h2-h3/python/bin:$PATH
export PYTHONPATH=/home/listepo.guest/zhttpd-perf-h2-h3/venv/lib/python3.13/site-packages
export OPENSSL_BIN="$root/openssl-install/bin/openssl"
/home/listepo.guest/zhttpd-build/zig-aarch64-linux-0.17.1/zig build test test-protocols -j2 -Dtls=true -Dhttp=true -Dopenssl="$root/openssl-install" -Dhttp-deps=/home/listepo.guest/zhttpd-perf-h2-h3/http-install -De2e-python=python3.13 --summary all
