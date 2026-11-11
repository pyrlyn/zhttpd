#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/deps"
if [ -f "$D/openssl-install/lib/libssl.a" ]; then exit 0; fi
J=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)
cd "$D/openssl-3.5.9"
export CC="$(mise which clang)"
export AR="$(mise which llvm-ar)"
export RANLIB="$(mise which llvm-ranlib)"
mise exec -- perl ./Configure no-shared no-tests no-docs --prefix="$D/openssl-install" --libdir=lib
mise exec -- make -j"$J"
mise exec -- make install_sw
