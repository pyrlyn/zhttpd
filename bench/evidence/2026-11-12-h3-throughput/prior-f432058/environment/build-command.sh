set -eu
root=/home/listepo.guest/zhttpd-perf-h3-throughput
host=/Users/listepo/apps/_worktrees/zhttpd-perf-h3-throughput
cp "$root/baseline/bin/zhttpd" "$root/baseline/bin/zhttpd-main44"
bash "$host/.run/build-new-baseline.sh"
tar -xf "$host/.run/integrated-candidate.tar" -C "$root/candidate"
cd "$root/candidate"
export PATH=/home/listepo.guest/zhttpd-perf-h2-h3/python/bin:$PATH
export PYTHONPATH=/home/listepo.guest/zhttpd-perf-h2-h3/venv/lib/python3.13/site-packages
export OPENSSL_BIN="$root/openssl-install/bin/openssl"
for mode in Debug ReleaseFast; do
 /home/listepo.guest/zhttpd-build/zig-aarch64-linux-0.17.1/zig build install test test-protocols test-features -j2 -Doptimize="$mode" -Dtls=true -Dhttp=true -Dopenssl="$root/openssl-install" -Dhttp-deps=/home/listepo.guest/zhttpd-perf-h2-h3/http-install -De2e-python=python3.13 --summary all
done
sha256sum zig-out/bin/zhttpd "$root/baseline/bin/zhttpd"
