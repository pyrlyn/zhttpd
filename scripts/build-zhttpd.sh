#!/usr/bin/env bash
# Build zhttpd (ReleaseFast, statically linked OpenSSL). No brew.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENSSL="${OPENSSL:-$ROOT/deps/openssl-install}"
cd "$ROOT"
mise exec -- zig build -Doptimize=ReleaseFast -Dtls=true -Dhttp=true -Dopenssl="$OPENSSL" -Dhttp-deps="${HTTP_DEPS:-$ROOT/deps/http-install}"
"$ROOT/zig-out/bin/zhttpd" -V
