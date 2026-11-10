#!/usr/bin/env bash
# Build OpenSSL (static) and nginx from verified sources in deps/ (no brew).
# Output: deps/openssl-install (libssl.a, libcrypto.a, headers), tools/nginx/sbin/nginx
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; D="$ROOT/deps"
J=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
if [ ! -f "$D/openssl-install/lib/libssl.a" ]; then
  (cd "$D/openssl-3.5.9" && ./Configure no-shared no-tests no-docs --prefix="$D/openssl-install" --libdir=lib \
     && make -j"$J" >/dev/null && make install_sw >/dev/null)
fi
cd "$D/nginx-1.30.6"
./configure --prefix="$ROOT/tools/nginx" \
  --with-cc-opt="-O2 -I$D/openssl-install/include" --with-ld-opt="-L$D/openssl-install/lib" \
  --with-http_ssl_module --with-http_v2_module --with-threads \
  --with-pcre="$D/pcre2-10.49" --with-zlib="$D/zlib-1.3.1" >/dev/null
make -j"$J" >/dev/null && make install >/dev/null
"$ROOT/tools/nginx/sbin/nginx" -V
