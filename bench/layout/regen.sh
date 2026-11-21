#!/usr/bin/env bash
# Regenerates the linker script that places the code and constants a serving
# worker uses side by side (src/hot-layout.ld, see docs/development.md):
#
#   bench/layout/regen.sh OUT.ld
#
# Linux only, meant for the bench VM (bench/lima). Needs gdb, binutils, rsync,
# openssl, sudo (page maps, fault-around) and oha with HTTP/3. OpenSSL and
# nghttp2 must be built with -ffunction-sections -fdata-sections. Works in
# $WORK; the source tree is only read.
# Environment: ZIG, OPENSSL, HTTP_DEPS, OHA, WORK, ROUNDS.
#
# 1. gdb records every function the worker and the master enter while serving.
# 2. Probe builds give every candidate constant a page of its own, and the
#    kernel's page map tells which of them are read. This repeats: a constant
#    becomes a candidate once it shows up on a page that was read.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; HERE="$ROOT/bench/layout"
OUT=${1:?usage: regen.sh OUT.ld}
B=${BUILD_DIR:-$HOME/zhttpd-build}
ZIG=${ZIG:-$B/zig-aarch64-linux-0.17.1/zig}
OPENSSL=${OPENSSL:-$B/openssl-install}; HTTP_DEPS=${HTTP_DEPS:-$B/http-install}
OHA=${OHA:-$B/oha}; W=${WORK:-$B/layout}; ROUNDS=${ROUNDS:-4}
PORT=48080; TLSPORT=48443; BIN=$W/src/zig-out/bin/zhttpd
ARCHIVES=("$OPENSSL/lib/libssl.a" "$OPENSSL/lib/libcrypto.a" "$HTTP_DEPS/lib/libnghttp2.a")
FAULT_AROUND=/sys/kernel/debug/fault_around_bytes
MASTER=; WORKER=; fault_around=

mkdir -p "$W/bench/certs" "$W/bench/www/static" "$W/tests/fixtures/nginx-default" "$W/run/logs"
cp "$ROOT/tests/fixtures/nginx-default/mime.types" "$W/tests/fixtures/nginx-default/"
[ -f "$W/bench/certs/cert.pem" ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 365 -subj "/CN=localhost" -keyout "$W/bench/certs/key.pem" -out "$W/bench/certs/cert.pem" 2>/dev/null
head -c 612 /dev/zero | tr '\0' x > "$W/bench/www/static/small.html"
[ -f "$W/bench/www/static/large.bin" ] || {
  head -c 65536 /dev/urandom > "$W/bench/www/static/medium.bin"
  head -c 1048576 /dev/urandom > "$W/bench/www/static/large.bin"
}

build() { # the layout script to link with
  rsync -a --delete --exclude .git --exclude .zig-cache --exclude zig-out --exclude 'deps/*' --exclude bench/results \
    --exclude bench/www --exclude bench/run --exclude tools --exclude .rtok --exclude .run "$ROOT/" "$W/src/"
  cp "$1" "$W/src/src/hot-layout.ld"
  (cd "$W/src" && "$ZIG" build -Doptimize=ReleaseFast -Dtls=true -Dhttp=true -Dopenssl="$OPENSSL" -Dhttp-deps="$HTTP_DEPS")
}
serve() { # the directive that replaces "http2 off;"; sets MASTER and WORKER
  sed -e "s#@ROOT@#$W#g" -e "s#@PORT@#$PORT#g" -e "s#@TLSPORT@#$TLSPORT#g" -e "s#use kqueue;#use epoll;#" \
    -e "s#worker_processes auto;#worker_processes 1;#" -e "s#http2 off;#$1#" \
    -e "s#keepalive_requests 1000000;#keepalive_requests 1000000000;#" "$ROOT/bench/nginx.conf.in" > "$W/run/nginx.conf"
  "$BIN" -p "$W/run/" -c "$W/run/nginx.conf" -q > "$W/server.log" 2>&1 &
  MASTER=$!
  for _ in $(seq 1 100); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/static/small.html" && break
    sleep 0.1
  done
  WORKER=$(awk '{print $1}' "/proc/$MASTER/task/$MASTER/children")
}
stop() {
  [ -z "$MASTER" ] || { kill -TERM "$MASTER" 2>/dev/null || true; wait "$MASTER" 2>/dev/null || true; }
  MASTER=
}
load() { # h1|tls|h2|h3, path, oha arguments
  local url=https://127.0.0.1:$TLSPORT$2 args=(--insecure)
  case $1 in
    h1) url=http://127.0.0.1:$PORT$2; args=() ;;
    h2) args+=(--http-version 2) ;;
    h3) args+=(--http-version 3) ;;
  esac
  timeout 120 "$OHA" --no-tui -w -t 60s "${args[@]}" "${@:3}" "$url" > /dev/null 2>&1 || true
}
generate() { # output, then generate.py options
  python3 "$HERE/generate.py" "$1" --trace "$W/trace.worker" "$W/trace.master" "$W/extra" --data "$W/data" \
    "${@:2}" --archives "${ARCHIVES[@]}"
}
trap 'stop; [ -z "$fault_around" ] || echo "$fault_around" | sudo tee $FAULT_AROUND > /dev/null' EXIT

echo "== functions"
build "$ROOT/src/hot-layout.ld"
sudo rm -f "$W"/trace.*
serve "http2 on; listen $TLSPORT quic reuseport;"
for who in worker master; do
  pid=$WORKER; [ $who = worker ] || pid=$MASTER
  sudo env TRACE_BIN="$BIN" TRACE_OUT="$W/trace.$who" gdb -q -batch -p "$pid" -x "$HERE/trace.py" > "$W/trace.$who.log" 2>&1 &
done
for _ in $(seq 1 1200); do
  [ ! -e "$W/trace.worker.armed" ] || [ ! -e "$W/trace.master.armed" ] || break
  sleep 0.5
done
for path in /static/small.html /static/large.bin /static/medium.bin /missing "/baseline11?a=1&b=2"; do
  load h1 "$path" -c 8 -n 200
  load tls "$path" -c 8 -n 200
  load h2 "$path" -c 4 -p 8 -n 200
  load h3 "$path" -c 4 -p 8 -n 200
done
load h1 /static/small.html -c 8 -n 100 --disable-keepalive
load tls /static/small.html -c 8 -n 100 --disable-keepalive
curl -s -o /dev/null -H 'Range: bytes=10-99' "http://127.0.0.1:$PORT/static/large.bin"
curl -s -o /dev/null -I "http://127.0.0.1:$PORT/static/small.html"
curl -s -o /dev/null -H 'If-Modified-Since: Sat, 21 Nov 2026 20:00:00 GMT' "http://127.0.0.1:$PORT/static/small.html"
sleep 3
stop
wait # gdb writes its list when the traced process exits
[ -s "$W/trace.worker" ] && [ -e "$W/trace.master" ] || { echo "tracing failed, see $W/trace.*.log" >&2; exit 1; }
echo "worker $(wc -l < "$W/trace.worker"), master $(wc -l < "$W/trace.master")"

# With fault-around the kernel maps the neighbours of every page that is read,
# which would hide what is really used.
fault_around=$(sudo cat $FAULT_AROUND)
echo 4096 | sudo tee $FAULT_AROUND > /dev/null
: > "$W/extra"; : > "$W/data"
for round in $(seq 1 "$ROUNDS"); do
  echo "== constants, round $round of $ROUNDS"
  generate "$W/probe.ld" --probe
  build "$W/probe.ld"
  : > "$W/syms.all"; : > "$W/literals.all"
  for scenario in h1:64:/static/small.html tls:64:/static/small.html h2:16:/static/small.html \
      h3:16:/static/small.html h2:4:/static/large.bin h3:4:/static/large.bin master; do
    IFS=: read -r proto conns path <<< "$scenario"
    [ "$scenario" != master ] || { proto=h1; conns=64; path=/static/small.html; }
    directive='http2 off;'; streams=()
    case $proto in
      h2) directive='http2 on;'; streams=(-p 16) ;;
      h3) directive="http2 on; listen $TLSPORT quic reuseport;"; streams=(-p 16) ;;
    esac
    serve "$directive"
    pid=$WORKER; [ "$scenario" != master ] || pid=$MASTER
    load "$proto" "$path" -c "$conns" -z 5s "${streams[@]}"
    sudo python3 "$HERE/pages.py" "$pid" "$BIN" --syms "$W/syms" > /dev/null
    cat "$W/syms" >> "$W/syms.all"; cat "$W/syms.literals" >> "$W/literals.all"
    stop
  done
  # named constants on the pages that were read, largest first
  awk -F'\t' '$2 ~ /^\.(rodata|data\.rel\.ro)/ && $2 !~ /\.lit\./ && $1 !~ /^__anon_/ && !seen[$1]++ {print $3 "\t" $1 "\t" $2}' \
    "$W/syms.all" | sort -n -r | awk -F'\t' '{print $2 "\t" $3 "\t" $1}' > "$W/data"
  # functions the trace missed: they were already running when gdb attached
  awk -F'\t' '$2 == ".text" && !seen[$1]++ {print $1 "\t" $3}' "$W/syms.all" > "$W/missed"
  cat "$W/missed" >> "$W/extra"
  echo "constants $(wc -l < "$W/data"), functions outside .text.hot $(wc -l < "$W/missed")"
done
# A constant still in .rodata only shares a page with one that is read; the
# probes have confirmed the rest.
awk -F'\t' '$2 != ".rodata"' "$W/data" > "$W/confirmed"
mv "$W/confirmed" "$W/data"
sort -n -u "$W/literals.all" | while read -r n; do sed -n "$((n + 1))p" "$W/probe.ld.members"; done > "$W/members"
generate "$OUT" --strings "$W/members"
