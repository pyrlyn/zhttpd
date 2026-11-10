#!/usr/bin/env bash
# Build zhttpd (ReleaseFast, statically linked OpenSSL). No brew.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENSSL="${OPENSSL:-$ROOT/deps/openssl-install}"
cd "$ROOT"
zig build -Doptimize=ReleaseFast -Dtls=true -Dopenssl="$OPENSSL"
"$ROOT/zig-out/bin/zhttpd" -V
