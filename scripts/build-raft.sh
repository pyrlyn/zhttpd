#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p zig-out/bin
go -C modules/raft build -trimpath -o ../../zig-out/bin/zhttpd-raft .
