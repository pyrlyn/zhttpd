#!/usr/bin/env bash
# zhttpd vs nginx vs the HttpArena HTTP/1.1 leader (bench/leaders.toml), same files,
# same nginx.conf for zhttpd and nginx, same load tool (oha, built into tools/oha).
#
#   bench/run.sh                      # full plan (see bench/PLAN.md)
#   bench/run.sh --quick              # 3 s runs, 1 repetition, fewer scenarios (smoke)
#   SERVERS="zhttpd nginx" bench/run.sh
#   DURATION=15 REPS=3 bench/run.sh
#   SCENARIO_FILTER='^https-' SERVERS="zhttpd nginx" bench/run.sh
#   WORKERS=1 SERVER_CPUS=0 LOAD_CPUS=1-3 bench/run.sh # Linux CPU isolation
#
# Output: bench/results/<timestamp>/ with one oha JSON per run, runs.csv, load.log,
# the exact nginx.conf used, and RESULTS.md (also copied to bench/RESULTS.md).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/bench"
CONF_TEMPLATE="${CONF_TEMPLATE:-$BENCH/nginx.conf.in}"
# Platform-native binaries: Linux builds live under tools/linux and zig-out-linux
# so a VM run never overwrites the Darwin ones.
if [ "$(uname)" = Linux ]; then
  OHA="${OHA:-$ROOT/tools/linux/oha}"
  ZHTTPD="${ZHTTPD:-$ROOT/zig-out-linux/bin/zhttpd}"
  NGINX="${NGINX:-$ROOT/tools/linux/nginx/sbin/nginx}"
  LEADER_BIN_DEFAULT="$ROOT/tools/linux/bin/dusty-arena"
else
  OHA="${OHA:-$ROOT/tools/oha/bin/oha}"
  ZHTTPD="${ZHTTPD:-$ROOT/zig-out/bin/zhttpd}"
  NGINX="${NGINX:-$ROOT/tools/nginx/sbin/nginx}"
  LEADER_BIN_DEFAULT="$BENCH/competitors/HttpArena/frameworks/dusty-tuned/zig-out/bin/dusty-arena"
fi
PORT="${PORT:-48080}"; TLSPORT="${TLSPORT:-48443}"
WORKERS="${WORKERS:-auto}"
[[ "$WORKERS" =~ ^(auto|[1-9][0-9]*)$ ]] || { echo "invalid WORKERS" >&2; exit 1; }
# Optional Linux CPU isolation: pin both servers identically and keep the load
# generator on separate CPUs so its own TLS work cannot hide server throughput.
SERVER_RUN=(env); LOAD_RUN=(env)
[ -z "${SERVER_CPUS:-}" ] || SERVER_RUN=(taskset -c "$SERVER_CPUS")
[ -z "${LOAD_CPUS:-}" ] || LOAD_RUN=(taskset -c "$LOAD_CPUS")
# raise the fd cap when the shell allows it (needed for c1024 + many TIME_WAIT)
ulimit -n 65535 2>/dev/null || ulimit -n 10240 2>/dev/null || true
DURATION="${DURATION:-10}"; WARMUP="${WARMUP:-2}"; REPS="${REPS:-2}"
# keep-alive-off runs are request-count bound: every request burns a loopback
# ephemeral port that then sits in TIME_WAIT (macOS: 16k ports, 2*MSL = 30 s)
NOKA_N="${NOKA_N:-12000}"
QUICK=0; [ "${1:-}" = "--quick" ] && { QUICK=1; DURATION=3; WARMUP=1; REPS=1; NOKA_N=6000; }

# leader for HTTP/1.1 from leaders.toml (python tomllib when available, else grep)
LEADER_NAME=$(python3 - "$BENCH/leaders.toml" <<'PY' 2>/dev/null || echo dusty-tuned
import sys
try:
    import tomllib
    d = tomllib.load(open(sys.argv[1], "rb"))
    print(d["http1"]["name"] if d["http1"].get("status") == "active" else "")
except ModuleNotFoundError:
    import re
    t = open(sys.argv[1]).read()
    m = re.search(r'\[http1\][^\[]*?name\s*=\s*"([^"]+)"', t, re.S)
    print(m.group(1) if m else "")
PY
)
LEADER_BIN="${LEADER_BIN:-$LEADER_BIN_DEFAULT}"
SERVERS="${SERVERS:-zhttpd nginx $LEADER_NAME}"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$BENCH/results/$STAMP"
mkdir -p "$OUT" "$BENCH/run/zhttpd/logs" "$BENCH/run/zhttpd-baseline/logs" "$BENCH/run/nginx/logs"

# ---------------------------------------------------------------- inputs
[ -f "$BENCH/certs/cert.pem" ] || "$ROOT/scripts/gen-certs.sh" || exit 1
mkdir -p "$BENCH/www/static"
python3 - "$BENCH/www/static" <<'PY'
import os, random, sys
d = sys.argv[1]
random.seed(42)
small = ("<!DOCTYPE html>\n<html>\n<head>\n<title>Welcome</title>\n</head>\n<body>\n"
         + "<p>" + "zhttpd benchmark page. " * 22 + "</p>\n</body>\n</html>\n")
open(os.path.join(d, "small.html"), "w").write(small[:612].ljust(612))
for name, size in (("medium.bin", 64 * 1024), ("large.bin", 1024 * 1024),
                   ("huge.bin", 100 * 1024 * 1024)):
    p = os.path.join(d, name)
    if not os.path.exists(p) or os.path.getsize(p) != size:
        with open(p, "wb") as f:
            for offset in range(0, size, 1024 * 1024):
                f.write(random.randbytes(min(1024 * 1024, size - offset)))
PY
EVENTS=kqueue; [ "$(uname)" = Linux ] && EVENTS=epoll
sed -e "s#@ROOT@#$ROOT#g" -e "s#@PORT@#$PORT#g" -e "s#@TLSPORT@#$TLSPORT#g" -e "s#use kqueue;#use $EVENTS;#" -e "s#worker_processes auto;#worker_processes $WORKERS;#" \
    "$CONF_TEMPLATE" > "$BENCH/nginx.conf"
cp "$BENCH/nginx.conf" "$OUT/nginx.conf"

# ---------------------------------------------------------------- scenarios
# name|scheme|keepalive(1/0)|connections|path
if [ $QUICK = 1 ]; then
SCENARIOS="http-small-ka-c64|http|1|64|/static/small.html
http-large-ka-c64|http|1|64|/static/large.bin
http-small-noka-c64|http|0|64|/static/small.html
https-small-ka-c64|https|1|64|/static/small.html
https-small-noka-c64|https|0|64|/static/small.html"
else
SCENARIOS="http-small-ka-c16|http|1|16|/static/small.html
http-small-ka-c64|http|1|64|/static/small.html
http-small-ka-c256|http|1|256|/static/small.html
http-small-ka-c1024|http|1|1024|/static/small.html
http-medium-ka-c64|http|1|64|/static/medium.bin
http-large-ka-c64|http|1|64|/static/large.bin
http-small-noka-c64|http|0|64|/static/small.html
http-baseline-ka-c256|http|1|256|/baseline11?a=1&b=2
https-small-ka-c64|https|1|64|/static/small.html
https-small-ka-c256|https|1|256|/static/small.html
https-large-ka-c64|https|1|64|/static/large.bin
https-huge-ka-c64|https|1|64|/static/huge.bin
https-small-noka-c64|https|0|64|/static/small.html"
fi

# ---------------------------------------------------------------- helpers
if [ -n "${SCENARIO_FILTER:-}" ]; then
  SCENARIOS=$(printf '%s\n' "$SCENARIOS" | grep -E "$SCENARIO_FILTER")
  [ -n "$SCENARIOS" ] || { echo "SCENARIO_FILTER matched no scenarios" >&2; exit 1; }
fi
printf '%s\n' "$SCENARIOS" > "$OUT/scenarios.txt"

loadavg() { if [ "$(uname)" = Darwin ]; then sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}'; else cut -d' ' -f1 /proc/loadavg; fi; }
ncpu() { if [ "$(uname)" = Darwin ]; then sysctl -n hw.ncpu; else nproc; fi; }

port_listening() {
  if [ "$(uname)" = Darwin ]; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    ss -lnt "( sport = :$1 )" 2>/dev/null | grep -q ":$1"
  fi
}

# Fail if something else is already bound — a leftover server would otherwise
# make start_server succeed (curl hits the old process) and poison the results.
require_ports_free() {
  local p
  for p in "$PORT" "$TLSPORT"; do
    if port_listening "$p"; then
      echo "!! port $p is already listening; refuse to start (leftover server?)" >&2
      lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null || ss -lntp "( sport = :$p )" 2>/dev/null || true
      return 1
    fi
  done
}

start_server() {
  require_ports_free || return 1
  case "$1" in
    zhttpd) "${SERVER_RUN[@]}" "$ZHTTPD" -p "$BENCH/run/zhttpd/" -c "$BENCH/nginx.conf" -q > "$OUT/zhttpd.stdout" 2>&1 & ;;
    zhttpd-baseline) "${SERVER_RUN[@]}" "${ZHTTPD_BASELINE:?set ZHTTPD_BASELINE}" -p "$BENCH/run/zhttpd-baseline/" -c "$BENCH/nginx.conf" -q > "$OUT/zhttpd-baseline.stdout" 2>&1 & ;;
    nginx)  "${SERVER_RUN[@]}" "$NGINX" -p "$BENCH/run/nginx/" -c "$BENCH/nginx.conf" -g 'daemon off;' > "$OUT/nginx.stdout" 2>&1 & ;;
    dusty-tuned)
      ( cd "$BENCH/www" && PORT=$PORT TLS_PORT=$TLSPORT STATIC_DIR="$BENCH/www/static" \
        TLS_CERT="$BENCH/certs/cert.pem" TLS_KEY="$BENCH/certs/key.pem" exec "${SERVER_RUN[@]}" "$LEADER_BIN" ) > "$OUT/dusty.stdout" 2>&1 & ;;
    *) echo "unknown server $1"; return 1 ;;
  esac
  SERVER_PID=$!
  local i
  for i in $(seq 1 100); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "!! $1 exited before it listened (pid $SERVER_PID)"; tail -n 20 "$OUT/$1.stdout" 2>/dev/null || tail -n 20 "$OUT/"*.stdout 2>/dev/null || true
      # map dusty-tuned log name
      [ "$1" = dusty-tuned ] && tail -n 20 "$OUT/dusty.stdout" 2>/dev/null || true
      [ "$1" = zhttpd ] && tail -n 20 "$OUT/zhttpd.stdout" 2>/dev/null || true
      [ "$1" = nginx ] && tail -n 20 "$OUT/nginx.stdout" 2>/dev/null || true
      return 1
    fi
    if port_listening "$PORT" && curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/static/small.html"; then
      return 0
    fi
    sleep 0.1
  done
  echo "!! $1 did not start"; return 1
}
stop_server() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 50); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
  local i
  for i in $(seq 1 50); do
    port_listening "$PORT" || return 0
    sleep 0.1
  done
  echo "!! port $PORT still listening after stop" >&2
  return 1
}

cleanup_bench() {
  stop_server || true
}
trap cleanup_bench EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Count TIME_WAIT sockets that mention our listen ports (max wait 90 s).
count_time_wait() {
  if [ "$(uname)" = Linux ]; then
    ss -tan state time-wait "( sport = :$PORT or dport = :$PORT or sport = :$TLSPORT or dport = :$TLSPORT )" 2>/dev/null | tail -n +2 | wc -l
  else
    netstat -an -p tcp 2>/dev/null | awk -v p=".${PORT}$" -v q=".${TLSPORT}$" '
      $NF=="TIME_WAIT" && ($4 ~ p || $5 ~ p || $4 ~ q || $5 ~ q) { n++ }
      END { print n+0 }'
  fi
}
wait_time_wait() {
  local n i
  for i in $(seq 1 180); do
    n=$(count_time_wait)
    [ "$n" -lt 1500 ] && return 0
    sleep 0.5
  done
  echo "(still $n TIME_WAIT after 90s, continuing)" >&2
}

oha_run() { # scheme ka conns path duration outfile  (duration "nN" = N requests)
  local port="$PORT"
  [ "$1" = https ] && port="$TLSPORT"
  local url="$1://127.0.0.1:$port$4"
  local args=(-c "$3" --no-tui --output-format json -w -t 10s)
  case "$5" in n*) args+=(-n "${5#n}") ;; *) args+=(-z "${5}s") ;; esac
  [ "$1" = https ] && args+=(--insecure)
  [ "$2" = 0 ] && args+=(--disable-keepalive)
  "${LOAD_RUN[@]}" "$OHA" "${args[@]}" "$url" > "$6" 2>"$6.err"
}

# ---------------------------------------------------------------- run
{
  echo "date: $(date)"
  echo "host: $(uname -a)"
  echo "cpus: $(ncpu)"
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ { print "memory_total_kib: " $2 }' /proc/meminfo
  else
    echo "memory_total_bytes: $(sysctl -n hw.memsize)"
  fi
  [ "$(uname)" = Darwin ] && echo "model: $(sysctl -n machdep.cpu.brand_string 2>/dev/null) / $(sysctl -n hw.memsize | awk '{printf "%.0f GiB", $1/1073741824}')"
  echo "oha: $("$OHA" --version)"
  echo "zhttpd: $("$ZHTTPD" -V 2>&1 | tr '\n' ' ')"
  echo "zhttpd_binary: $ZHTTPD"
  [ -z "${ZHTTPD_BASELINE:-}" ] || echo "zhttpd-baseline: $ZHTTPD_BASELINE"
  echo "nginx: $("$NGINX" -V 2>&1 | tr '\n' ' ')"
  python3 - "$ZHTTPD" "$NGINX" "${ZHTTPD_BASELINE:-}" <<'PY'
import hashlib, sys
for label, path in zip(('zhttpd', 'nginx', 'zhttpd-baseline'), sys.argv[1:]):
    if path:
        with open(path, 'rb') as binary:
            print(f'{label}_sha256: {hashlib.file_digest(binary, "sha256").hexdigest()}')
PY
  LEADER_SRC="$BENCH/competitors/HttpArena"
[ -d "$LEADER_SRC" ] || LEADER_SRC="/Users/listepo/Grok/zig-http-server/bench/competitors/HttpArena"
echo "leader: $LEADER_NAME ($(git -C "$LEADER_SRC" log -1 --format=%H 2>/dev/null))"
  echo "duration=${DURATION}s warmup=${WARMUP}s keepalive-off=${NOKA_N} requests reps=$REPS servers=[$SERVERS]"
  echo "workers=$WORKERS server_cpus=${SERVER_CPUS:-unbound} load_cpus=${LOAD_CPUS:-unbound} scenario_filter=${SCENARIO_FILTER:-all}"
} > "$OUT/env.txt"
echo "rep,order,server,scenario,load_before,load_after,file" > "$OUT/runs.csv"
cat "$OUT/env.txt"

read -r -a SV <<< "$SERVERS"
for rep in $(seq 1 "$REPS"); do
  # ABBA: odd repetitions run A B C, even ones C B A
  if [ $((rep % 2)) = 1 ]; then ORDER=("${SV[@]}"); else ORDER=(); for ((i=${#SV[@]}-1; i>=0; i--)); do ORDER+=("${SV[$i]}"); done; fi
  pos=0
  for srv in "${ORDER[@]}"; do
    pos=$((pos+1))
    echo "== rep $rep/$REPS: $srv (load $(loadavg))"
    { echo "--- rep $rep $srv $(date +%T) load=$(loadavg)"
      if [ "$(uname)" = Darwin ]; then ps -Ao pcpu,comm -r | head -6
      else ps -eo pcpu,comm --sort=-pcpu | head -6
      fi; } >> "$OUT/load.log"
    start_server "$srv" || exit 1
    while IFS='|' read -r name scheme ka conns path; do
      [ -z "$name" ] && continue
      wait_time_wait
      if [ "$ka" = 1 ]; then w="$WARMUP"; d="$DURATION"; else w="n500"; d="n$NOKA_N"; fi
      oha_run "$scheme" "$ka" "$conns" "$path" "$w" /dev/null >/dev/null 2>&1
      [ "$ka" = 0 ] && wait_time_wait
      lb=$(loadavg)
      f="$OUT/$name.$srv.r$rep.json"
      oha_run "$scheme" "$ka" "$conns" "$path" "$d" "$f" || exit 1
      la=$(loadavg)
      echo "$rep,$pos,$srv,$name,$lb,$la,$(basename "$f")" >> "$OUT/runs.csv"
      printf '   %-24s %s\n' "$name" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%.0f rps" % d["summary"]["requestsPerSec"])' "$f" 2>/dev/null || echo error)"
    done <<< "$SCENARIOS"
    stop_server
  done
done

python3 "$BENCH/report.py" "$OUT" || exit 1
cp "$OUT/RESULTS.md" "$BENCH/RESULTS.md" || exit 1
echo "results: $OUT/RESULTS.md (copied to bench/RESULTS.md)"
