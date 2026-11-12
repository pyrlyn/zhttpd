#!/usr/bin/env bash
# Download third-party sources into deps/ and verify checksums.
# OpenSSL: verified against the .sha256 published next to the tarball.
# nginx / pcre2 / zlib: pinned sha256 recorded in deps/SHA256SUMS on first fetch
# (trust-on-first-use; re-runs fail if a tarball changes).
set -euo pipefail
cd "$(dirname "$0")/../deps"
NGINX=1.30.6; OPENSSL=3.5.9; PCRE2=10.49; ZLIB=1.3.1
fetch() { # url file
  [ -f "$2" ] || curl -fsSL -o "$2.part" "$1" && { [ -f "$2" ] || mv "$2.part" "$2"; }
}
fetch "https://nginx.org/download/nginx-$NGINX.tar.gz" nginx-$NGINX.tar.gz
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" openssl-$OPENSSL.tar.gz
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz.sha256" openssl-$OPENSSL.tar.gz.sha256
fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2/pcre2-$PCRE2.tar.gz" pcre2-$PCRE2.tar.gz
fetch "https://zlib.net/fossils/zlib-$ZLIB.tar.gz" zlib-$ZLIB.tar.gz
want=$(awk '{print $1}' openssl-$OPENSSL.tar.gz.sha256); got=$(shasum -a 256 openssl-$OPENSSL.tar.gz | awk '{print $1}')
[ "$want" = "$got" ] || { echo "openssl sha256 mismatch: $got != $want"; exit 1; }
echo "openssl-$OPENSSL sha256 OK (published): $got"
if [ -f SHA256SUMS ]; then shasum -a 256 -c SHA256SUMS; else
  shasum -a 256 nginx-$NGINX.tar.gz openssl-$OPENSSL.tar.gz pcre2-$PCRE2.tar.gz zlib-$ZLIB.tar.gz > SHA256SUMS; cat SHA256SUMS; fi
for t in nginx-$NGINX openssl-$OPENSSL pcre2-$PCRE2 zlib-$ZLIB; do [ -d $t ] || tar xzf $t.tar.gz; done
# Protocol libraries: hashes published with the pinned GitHub release assets.
for spec in \
  'nghttp2/nghttp2 1.71.0 0cdd35ecec77919b4b7b245f87fe8d2216e3d62da854eb0838c594ff058042fc'; do
  read -r repo version hash <<< "$spec"
  name="${repo##*/}-$version"
  fetch "https://github.com/$repo/releases/download/v$version/$name.tar.gz" "$name.tar.gz"
  [ "$(shasum -a 256 "$name.tar.gz" | awk '{print $1}')" = "$hash" ] || { echo "$name checksum mismatch" >&2; exit 1; }
  [ -d "$name" ] || tar xzf "$name.tar.gz"
done
echo done
