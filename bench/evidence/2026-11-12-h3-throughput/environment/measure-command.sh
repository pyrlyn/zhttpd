set -eu
root=/home/listepo.guest/zhttpd-perf-h3-throughput
cd "$root/candidate"
mkdir -p "$root/final-environment"
ps -eo pid,ppid,pcpu,args > "$root/final-environment/before.txt"
uname -a > "$root/final-environment/kernel.txt"
sha256sum zig-out/bin/zhttpd "$root/baseline/bin/zhttpd" > "$root/final-environment/servers.sha256"
(while :; do date -u +%FT%TZ; ps -eo pid,ppid,pcpu,comm,args; sleep 2; done) > "$root/final-environment/processes.txt" & monitor=$!
trap 'kill "$monitor" 2>/dev/null || true; wait "$monitor" 2>/dev/null || true' EXIT
export DURATION=10 WARMUP=2 REPS=4 PORT=29880 TLSPORT=29443 STREAMS=16
export OHA=/home/listepo.guest/zhttpd-perf-h2-h3/oha-drain/bin/oha
export NGINX=/home/listepo.guest/zhttpd-perf-h2-h3/nginx/sbin/nginx
export ZHTTPD="$PWD/zig-out/bin/zhttpd" ZHTTPD_BASELINE="$root/baseline/bin/zhttpd"
export WORKERS=1 SERVER_CPUS=0 LOAD_CPUS=1-7 SERVERS='zhttpd-baseline nginx zhttpd'
HTTP_VERSION=2 SCENARIO_FILTER='small-ka-c4|large' bash bench/run.sh
HTTP_VERSION=3 bash bench/run.sh
