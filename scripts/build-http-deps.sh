#!/usr/bin/env bash
# Build the HTTP/2 codec with the pinned mise toolchain (HTTP/3 is in-tree).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HTTP_CLANG="$(mise which clang)"
HTTP_AR="$(mise which llvm-ar)"
HTTP_RANLIB="$(mise which llvm-ranlib)"
for source in nghttp2-1.71.0; do
  mise exec -- cmake -S "$ROOT/deps/$source" -B "$ROOT/deps/$source/build-mise" \
    -DCMAKE_C_COMPILER="$HTTP_CLANG" -DCMAKE_CXX_COMPILER="$HTTP_CLANG" -DCMAKE_CXX_COMPILER_ARG1=--driver-mode=g++ -DCMAKE_AR="$HTTP_AR" -DCMAKE_RANLIB="$HTTP_RANLIB" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$ROOT/deps/http-install" \
    -DCMAKE_INSTALL_LIBDIR=lib -DENABLE_LIB_ONLY=ON -DENABLE_APP=OFF -DENABLE_EXAMPLES=OFF -DENABLE_SHARED_LIB=OFF \
    -DENABLE_STATIC_LIB=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF
  mise exec -- cmake --build "$ROOT/deps/$source/build-mise" --parallel 8
  mise exec -- cmake --install "$ROOT/deps/$source/build-mise"
done
