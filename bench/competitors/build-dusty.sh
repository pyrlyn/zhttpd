#!/usr/bin/env bash
# Fetch HttpArena's dusty-tuned entry (sparse checkout) and build it like its Dockerfile
# (zig build --release=fast), with zhttpd's small patch: PORT / TLS_PORT / STATIC_DIR
# environment variables instead of the fixed 8080/8081 and /data/static.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
[ -d HttpArena ] || git clone -q --depth 1 --filter=blob:none --sparse https://github.com/MDA2AV/HttpArena
cd HttpArena
git sparse-checkout set frameworks/dusty-tuned
git -C . log -1 --format='HttpArena commit %H (%cd)'
cd frameworks/dusty-tuned
git diff --quiet -- src/main.zig && git apply "$HERE/dusty-tuned.patch"
zig build --release=fast
ls -la zig-out/bin/dusty-arena
