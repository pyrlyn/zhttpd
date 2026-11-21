#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/deps"
# Every deps/patches/openssl-*.patch, in name order, plus the C checks that run
# against the installed archive.
PATCHES=("$D"/patches/openssl-*.patch)
CHECKS=(quic-stream-gc openssl-tls-mem)
STAMP="$D/openssl-install/.zhttpd-patches"
INPUT_HASH=$( (cat "${PATCHES[@]}"; for t in "${CHECKS[@]}"; do cat "$ROOT/tests/$t.c"; done
  cat "$D/SHA256SUMS" "$ROOT/mise.toml" "$ROOT/scripts/build-openssl.sh") | shasum -a 256 | awk '{print $1}')
if [ -f "$D/openssl-install/lib/libssl.a" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$INPUT_HASH" ]; then exit 0; fi
J=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)
cd "$D/openssl-3.5.9"
# Apply once; reject source drift instead of accepting an unpatched cache.
for p in "${PATCHES[@]}"; do
  if patch -N -p1 --dry-run < "$p" >/dev/null 2>&1; then
    patch -N -p1 < "$p"
  elif ! patch -f -R -p1 --dry-run < "$p" >/dev/null 2>&1; then
    echo "OpenSSL patch $(basename "$p") does not match the pinned source" >&2
    exit 1
  fi
done
export CC="$(mise which clang)"
export AR="$(mise which llvm-ar)"
export RANLIB="$(mise which llvm-ranlib)"
# SSL_MAX_PIPELINES sizes structs across libssl: never mix objects built
# before and after a patch changed it.
[ ! -f Makefile ] || mise exec -- make clean >/dev/null
mise exec -- perl ./Configure no-shared no-tests no-docs --prefix="$D/openssl-install" --libdir=lib
mise exec -- make -j"$J"
mise exec -- make install_sw

# Check the actual installed archive: QUIC stream retention before the final
# ACK, released TLS 1.3 key shares and the single record pipeline.
mkdir -p "$ROOT/.run"
LINK_LIBS=(-pthread)
[ "$(uname -s)" != Linux ] || LINK_LIBS+=(-ldl)
for t in "${CHECKS[@]}"; do
  mise exec -- "$CC" -I. -Iinclude "$ROOT/tests/$t.c" \
    "$D/openssl-install/lib/libssl.a" "$D/openssl-install/lib/libcrypto.a" \
    "${LINK_LIBS[@]}" -o "$ROOT/.run/$t"
  "$ROOT/.run/$t"
done
printf '%s\n' "$INPUT_HASH" > "$STAMP"
