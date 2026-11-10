#!/usr/bin/env bash
# Smoke test: serve one nginx.conf with zhttpd and (if built) with nginx, run the same
# curl checks against both and diff the normalized results.
#   scripts/smoke.sh            # zhttpd + nginx (tools/nginx/sbin/nginx)
#   NGINX=none scripts/smoke.sh # zhttpd only
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/.run/smoke"
ZHTTPD="${ZHTTPD:-$ROOT/zig-out/bin/zhttpd}"
NGINX="${NGINX:-$ROOT/tools/nginx/sbin/nginx}"
PORT="${PORT:-38080}"; TLSPORT="${TLSPORT:-38443}"; UPORT="${UPORT:-38081}"
CERTS="$ROOT/bench/certs"

mkdir -p "$RUN"/{conf,html/sub,html/static,html/errors,zhttpd/logs,nginx/logs,results}
[ -f "$CERTS/cert.pem" ] || "$ROOT/scripts/gen-certs.sh" || exit 1
cp "$ROOT/tests/fixtures/nginx-default/mime.types" "$RUN/conf/"
sed -e "s#@RUN@#$RUN#g" -e "s#@PORT@#$PORT#g" -e "s#@TLSPORT@#$TLSPORT#g" -e "s#@UPORT@#$UPORT#g" -e "s#@CERTS@#$CERTS#g" \
    "$ROOT/scripts/smoke.conf.in" > "$RUN/conf/nginx.conf"

# content
printf '<h1>home</h1>\n' > "$RUN/html/index.html"
printf 'sub index\n' > "$RUN/html/sub/index.html"
printf 'about page\n' > "$RUN/html/about.html"
printf 'body{color:red}\n' > "$RUN/html/static/site.css"
printf 'static text\n' > "$RUN/html/static/a.txt"
printf '<h1>custom 404</h1>\n' > "$RUN/html/errors/404.html"
printf '<h1>custom 50x</h1>\n' > "$RUN/html/errors/50x.html"
 head -c 2097152 /dev/urandom > "$RUN/html/big.bin"

python3 "$ROOT/scripts/upstream.py" "$UPORT" & UPID=$!
trap 'kill $UPID 2>/dev/null' EXIT
sleep 0.5

H="http://127.0.0.1:$PORT"; S="https://localhost:$TLSPORT"
CURL=(curl -s -S --max-time 5 -k -o /tmp/zsmoke.body -D /tmp/zsmoke.head)

# name | curl arguments
CHECKS=$(cat <<EOC
get-root|$H/
get-http10|-0 $H/
head-root|-I $H/
not-found-custom-page|$H/nope
try-files-dir|$H/sub
try-files-dir-slash|$H/sub/
try-files-html-ext|$H/about
exact|$H/exact
prefix-noregex|$H/static/site.css
regex-icase|$H/x/APP.JS
internal-location|$H/errors/404.html
post-static-405|-X POST -d x $H/index.html
proxy-get|$H/api/hello?a=1
proxy-post|-X POST -d hello=world $H/api/form
proxy-post-chunked|-X POST -H Transfer-Encoding:chunked --data-binary @/etc/hosts $H/api/chunked
proxy-raw-uri|$H/raw/a%20b?x=1
proxy-var-upstream|$H/dyn/x?y=1
proxy-var-ip|-H X-Backend:direct $H/dyn/z
proxy-no-length|$H/api/nolen
proxy-no-length-http10|-0 $H/api/nolen
proxy-upstream-500|$H/api/status/500
proxy-down-502|$H/down/
rewrite-permanent|$H/old/a.txt
rewrite-last|$H/internal-rewrite/a.txt
return-444|$H/gone
return-418|$H/teapot
deny|$H/private/x
set-if-map|-H X-Variant:beta1 $H/var?user=ivan
named-capture|$H/users/42
vhost-regex|-H Host:foo.example.test $H/
vhost-wildcard|-H Host:a.wild.test $H/p?q=1
conditional-304|-H @$RUN/ims.hdr $H/index.html
range|-r 0-9 $H/big.bin
big-file|$H/big.bin
too-large-413|-X POST --data-binary @$RUN/html/big.bin $H/api/x
bad-request-no-host|-H Host: $H/
https-get|$S/
https-proxy-post|-X POST -d tls=1 $S/api/tls
EOC
)

run_checks() { # $1 = label
  local out="$RUN/results/$1.txt"; : > "$out"
  curl -s -I "$H/index.html" | awk -F': ' 'tolower($1)=="last-modified"{print "If-Modified-Since: " $2}' | tr -d '\r' > "$RUN/ims.hdr"
  while IFS='|' read -r name args; do
    [ -z "$name" ] && continue
    rm -f /tmp/zsmoke.body /tmp/zsmoke.head
    # shellcheck disable=SC2086
    "${CURL[@]}" $args >/dev/null 2>/tmp/zsmoke.err; rc=$?
    status=$(head -1 /tmp/zsmoke.head 2>/dev/null | tr -d '\r' | cut -d' ' -f2)
    hdrs=$(grep -iE '^(content-type|content-length|location|connection|transfer-encoding|content-range|accept-ranges|x-static|x-asset|x-upstream|expires|cache-control|etag|last-modified):' /tmp/zsmoke.head 2>/dev/null \
      | tr -d '\r' | awk 'BEGIN{FS=OFS=": "} {$1=tolower($1); print}' | sed -E 's/^(expires|last-modified): .*/\1: <date>/; s/^etag: .*/etag: <etag>/; s/^cache-control: max-age=[0-9]+/cache-control: max-age=N/' | sort | paste -sd ';' -)
    body=$(grep -avE '^(Date|Server): ' /tmp/zsmoke.body 2>/dev/null | sed -E 's#(zhttpd/[0-9.]+|nginx/[0-9.]+|zhttpd|nginx)#SERVER#g' 2>/dev/null | cksum | awk '{print $1 "/" $2}')
    printf '%-26s rc=%s status=%s %s body=%s\n' "$name" "$rc" "${status:--}" "$hdrs" "$body" >> "$out"
  done <<< "$CHECKS"
  # keep-alive: 3 requests over one connection (num_connects summed)
  conns=$(curl -s -o /dev/null -o /dev/null -o /dev/null -w '%{num_connects}\n' "$H/" "$H/exact" "$H/api/k" | awk '{s+=$1} END {print s}')
  printf '%-26s connections=%s\n' "keepalive-3-requests" "$conns" >> "$out"
  conns=$(curl -s -k -o /dev/null -o /dev/null -w '%{num_connects}\n' "$S/" "$S/exact" | awk '{s+=$1} END {print s}')
  printf '%-26s connections=%s\n' "https-keepalive-2" "$conns" >> "$out"
  # pipelining: 3 requests in one write
  pipe=$(python3 - "$PORT" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"GET /exact HTTP/1.1\r\nHost: a\r\n\r\nGET /static/a.txt HTTP/1.1\r\nHost: a\r\n\r\nGET /exact HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
s.settimeout(3); data = b""
try:
    while True:
        d = s.recv(65536)
        if not d: break
        data += d
except Exception: pass
import re
print(" ".join(m.decode() for m in re.findall(rb"HTTP/1\.1 (\d{3}) ", data)))
PY
)
  printf '%-26s statuses=%s\n' "pipelined-3" "$pipe" >> "$out"
}

start_server() { # $1 label, rest: command
  local label=$1; shift
  "$@" -g 'daemon off;' > "$RUN/$label/stdout.log" 2>&1 &
  echo $! > "$RUN/$label.pid"
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0; sleep 0.1; done
  echo "server $label did not start:"; cat "$RUN/$label/stdout.log"; return 1
}
stop_server() { kill "$(cat "$RUN/$1.pid")" 2>/dev/null; sleep 0.5; }

if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then echo "port $PORT is busy, stop the other server first"; exit 1; fi
echo "== zhttpd -t"
"$ZHTTPD" -t -p "$RUN/zhttpd/" -c "$RUN/conf/nginx.conf" || exit 1
start_server zhttpd "$ZHTTPD" -p "$RUN/zhttpd/" -c "$RUN/conf/nginx.conf" || exit 1
run_checks zhttpd; stop_server zhttpd
echo "== zhttpd results ($RUN/results/zhttpd.txt)"; cat "$RUN/results/zhttpd.txt"

if [ "$NGINX" != none ] && [ -x "$NGINX" ]; then
  echo "== nginx -t"
  "$NGINX" -t -p "$RUN/nginx/" -c "$RUN/conf/nginx.conf" 2>&1 | tail -2
  start_server nginx "$NGINX" -p "$RUN/nginx/" -c "$RUN/conf/nginx.conf" || exit 1
  run_checks nginx; stop_server nginx
  echo "== diff nginx vs zhttpd (empty = identical)"
  diff "$RUN/results/nginx.txt" "$RUN/results/zhttpd.txt" && echo "IDENTICAL"
fi
