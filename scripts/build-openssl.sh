#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/deps"
PATCH="$D/patches/openssl-quic-stream-gc.patch"
STAMP="$D/openssl-install/.zhttpd-quic-gc"
INPUT_HASH=$(cat "$PATCH" "$ROOT/tests/quic-stream-gc.c" "$D/SHA256SUMS" \
  "$ROOT/mise.toml" "$ROOT/scripts/build-openssl.sh" | shasum -a 256 | awk '{print $1}')
if [ -f "$D/openssl-install/lib/libssl.a" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$INPUT_HASH" ]; then exit 0; fi
J=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)
cd "$D/openssl-3.5.9"
# Apply once; reject source drift instead of accepting an unpatched cache.
if patch -N -p1 --dry-run < "$PATCH" >/dev/null 2>&1; then
  patch -N -p1 < "$PATCH"
elif ! patch -f -R -p1 --dry-run < "$PATCH" >/dev/null 2>&1; then
  echo "OpenSSL QUIC stream GC patch does not match the pinned source" >&2
  exit 1
fi
export CC="$(mise which clang)"
export AR="$(mise which llvm-ar)"
export RANLIB="$(mise which llvm-ranlib)"
mise exec -- perl ./Configure no-shared no-tests no-docs --prefix="$D/openssl-install" --libdir=lib
mise exec -- make -j"$J"
mise exec -- make install_sw

# Check the actual installed archive, including retention before the final ACK.
mkdir -p "$ROOT/.run"
LINK_LIBS=(-pthread)
[ "$(uname -s)" != Linux ] || LINK_LIBS+=(-ldl)
mise exec -- "$CC" -I. -Iinclude "$ROOT/tests/quic-stream-gc.c" \
  "$D/openssl-install/lib/libssl.a" "$D/openssl-install/lib/libcrypto.a" \
  "${LINK_LIBS[@]}" -o "$ROOT/.run/quic-stream-gc"
"$ROOT/.run/quic-stream-gc"
printf '%s\n' "$INPUT_HASH" > "$STAMP"
