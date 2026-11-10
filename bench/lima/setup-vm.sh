#!/usr/bin/env bash
# Build Linux binaries for the zhttpd bench inside the zhttpd-bench Lima VM.
# Safe to re-run. Never writes Darwin outputs (tools/nginx, tools/oha, zig-out).
set -euo pipefail
ROOT="${ROOT:-/Users/listepo/Grok/zig-http-server}"
if [ "$(uname)" != Linux ]; then
  echo "setup-vm.sh must run inside the Linux VM, not on $(uname)" >&2
  exit 1
fi
if [ ! -d "$ROOT" ]; then
  echo "project mount $ROOT is missing" >&2
  exit 1
fi
NPROC=$(nproc)
BUILD="${BUILD_DIR:-$HOME/zhttpd-build}"
# Prefer a prefix on the guest disk: Lima virtiofs of the Mac project may be
# readable but not writable (EPERM) even when mounted rw.
LINUX="${LINUX:-$ROOT/tools/linux}"
ZHTTPD_PREFIX="${ZHTTPD_PREFIX:-$ROOT/zig-out-linux}"
CACHE="${CACHE:-$ROOT/tools/linux/cache}"
mkdir -p "$BUILD" "$LINUX/bin" "$CACHE" "$ZHTTPD_PREFIX"

need() { command -v "$1" >/dev/null 2>&1; }
if ! need cc || ! need make || ! need curl || ! need xz; then
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends build-essential curl ca-certificates xz-utils pkg-config
fi

# Zig 0.17.1 (same as the Mac). Official tarball, not apt (too old) and not brew.
ZIGVER="${ZIGVER:-0.17.1}"
ZIGDIR="$BUILD/zig-aarch64-linux-$ZIGVER"
if [ ! -x "$ZIGDIR/zig" ]; then
  tarball="$CACHE/zig-aarch64-linux-$ZIGVER.tar.xz"
  if [ ! -f "$tarball" ]; then
    # download onto the guest disk, not the (possibly read-only) project mount
    tarball="$BUILD/zig-aarch64-linux-$ZIGVER.tar.xz"
    curl -L --fail -o "$tarball" "https://ziglang.org/download/$ZIGVER/zig-aarch64-linux-$ZIGVER.tar.xz"
  fi
  tar -xJf "$tarball" -C "$BUILD"
fi
export PATH="$ZIGDIR:$PATH"
# zig must not write .zig-cache into the (possibly EPERM) project mount
export ZIG_GLOBAL_CACHE_DIR="$BUILD/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="$BUILD/zig-local-cache"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
zig version

# OpenSSL: extract the official tarball onto the guest disk (the already-built
# Darwin tree in deps/openssl-3.5.9 must not be configured again).
SSL_SRC="$BUILD/openssl-3.5.9"
SSL_PREFIX="$BUILD/openssl-install"
if [ ! -f "$SSL_PREFIX/lib/libssl.a" ]; then
  rm -rf "$SSL_SRC"
  tar -xzf "$ROOT/deps/openssl-3.5.9.tar.gz" -C "$BUILD"
  (cd "$SSL_SRC" && ./Configure no-shared no-tests no-docs --prefix="$SSL_PREFIX" --libdir=lib linux-aarch64)
  make -C "$SSL_SRC" -j"$NPROC"
  make -C "$SSL_SRC" install_sw
fi

# nginx 1.30.6, out of tree copy (its configure writes into the source tree)
NGINX_SRC_HOST="$ROOT/deps/nginx-1.30.6"
NGINX_SRC="$BUILD/nginx-1.30.6"
NGINX_PREFIX="$LINUX/nginx"
if [ ! -x "$NGINX_PREFIX/sbin/nginx" ]; then
  rm -rf "$NGINX_SRC"
  cp -a "$NGINX_SRC_HOST" "$NGINX_SRC"
  # drop Darwin objects if the copy included any
  make -C "$NGINX_SRC" clean >/dev/null 2>&1 || true
  # nginx builds pcre/zlib in-tree; copy them so Darwin objects in deps/ stay untouched
  rm -rf "$BUILD/pcre2-10.49" "$BUILD/zlib-1.3.1"
  cp -a "$ROOT/deps/pcre2-10.49" "$BUILD/pcre2-10.49"
  cp -a "$ROOT/deps/zlib-1.3.1" "$BUILD/zlib-1.3.1"
  make -C "$BUILD/pcre2-10.49" distclean >/dev/null 2>&1 || make -C "$BUILD/pcre2-10.49" clean >/dev/null 2>&1 || true
  make -C "$BUILD/zlib-1.3.1" distclean >/dev/null 2>&1 || make -C "$BUILD/zlib-1.3.1" clean >/dev/null 2>&1 || true
  (cd "$NGINX_SRC" && ./configure --prefix="$NGINX_PREFIX" \
    --with-cc-opt="-O2 -I$SSL_PREFIX/include" --with-ld-opt="-L$SSL_PREFIX/lib" \
    --with-http_ssl_module --with-http_v2_module --with-threads --with-file-aio \
    --with-pcre="$BUILD/pcre2-10.49" --with-zlib="$BUILD/zlib-1.3.1")
  make -C "$NGINX_SRC" -j"$NPROC"
  make -C "$NGINX_SRC" install
fi
"$NGINX_PREFIX/sbin/nginx" -V

# zhttpd → zig-out-linux (ReleaseFast + TLS, static OpenSSL)
if [ ! -x "$ZHTTPD_PREFIX/bin/zhttpd" ]; then
  (cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dtls=true -Dopenssl="$SSL_PREFIX" -p "$ZHTTPD_PREFIX")
fi
"$ZHTTPD_PREFIX/bin/zhttpd" -V

# dusty-tuned → separate prefix, do not overwrite Darwin zig-out
# Copy dusty off the (possibly EPERM) mount — its build writes generated sources.
DUSTY_SRC="$ROOT/bench/competitors/HttpArena/frameworks/dusty-tuned"
DUSTY="$BUILD/dusty-tuned"
if [ ! -x "$LINUX/bin/dusty-arena" ]; then
  if [ ! -d "$DUSTY_SRC" ]; then
    echo "dusty-tuned tree missing; run bench/competitors/build-dusty.sh on the Mac first" >&2
    exit 1
  fi
  rm -rf "$DUSTY"
  cp -a "$DUSTY_SRC" "$DUSTY"
  (cd "$DUSTY" && zig build --release=fast -p "$BUILD/dusty")
  cp -a "$BUILD/dusty/bin/dusty-arena" "$LINUX/bin/dusty-arena"
fi

# oha: official Linux arm64 release if present in cache, else cargo if available, else go-get skip
OHA="$LINUX/oha"
if [ ! -x "$OHA" ]; then
  if [ -x "$CACHE/oha-linux-arm64" ]; then
    cp "$CACHE/oha-linux-arm64" "$OHA" && chmod +x "$OHA"
  else
    # try known release asset names for 1.16.0
    for asset in oha-linux-arm64 oha-aarch64-unknown-linux-gnu oha-v1.16.0-aarch64-unknown-linux-gnu; do
      url="https://github.com/hatoo/oha/releases/download/v1.16.0/$asset"
      if curl -L --fail -o "$CACHE/$asset" "$url"; then
        chmod +x "$CACHE/$asset"
        # tarball vs raw binary
        if file "$CACHE/$asset" | grep -q 'executable\|ELF'; then
          cp "$CACHE/$asset" "$OHA" && break
        fi
      fi
    done
  fi
fi
if [ ! -x "$OHA" ]; then
  echo "oha Linux binary not installed; download the official aarch64 release into $CACHE" >&2
  exit 1
fi
"$OHA" --version
echo "Linux bench tools ready under $LINUX and $ZHTTPD_PREFIX"
