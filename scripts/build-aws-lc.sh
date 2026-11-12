#!/usr/bin/env bash
# Optional TLS backend. The default OpenSSL dependency is unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=5.14.0
COMMIT=7821a7544c6dce1bb5fc927aa273d4ee7a536988
SOURCE="${AWS_LC_SOURCE:-$ROOT/deps/aws-lc-$VERSION}"
BUILD="${AWS_LC_BUILD:-$ROOT/deps/aws-lc-build-$VERSION}"
PREFIX="${AWS_LC_PREFIX:-$ROOT/deps/aws-lc-install}"
PATCH="$ROOT/scripts/patches/aws-lc-$VERSION-linux-apple.patch"

if [ ! -d "$SOURCE" ]; then
  git clone --depth 1 --branch "v$VERSION" https://github.com/aws/aws-lc.git "$SOURCE"
fi
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT" ] || {
  echo "AWS-LC source must be pinned to $COMMIT" >&2; exit 1;
}
# Apply only the reviewed Linux CPU-detection fix. Algorithms and assembly stay
# upstream. Re-runs accept precisely this patch; all other tracked edits fail.
if [ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ]; then
  git -C "$SOURCE" apply "$PATCH"
fi
observed_diff=$(mktemp)
trap 'rm -f "$observed_diff"' EXIT
git -C "$SOURCE" diff --no-ext-diff --binary --full-index --no-color \
  --src-prefix=a/ --dst-prefix=b/ --unified=3 HEAD -- > "$observed_diff"
cmp -s "$PATCH" "$observed_diff" || {
  echo "AWS-LC source must contain exactly the reviewed patch: $PATCH" >&2; exit 1;
}
cmake -S "$SOURCE" -B "$BUILD" -GNinja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_TOOL=OFF -DDISABLE_GO=ON
cmake --build "$BUILD" --parallel "${JOBS:-4}"
cmake --install "$BUILD"
printf '\nAWS-LC %s (%s) installed at %s\n' "$VERSION" "$COMMIT" "$PREFIX"
printf 'Build: zig build -Doptimize=ReleaseFast -Dtls=true -Dtls-backend=aws_lc -Dopenssl=%s\n' "$PREFIX"
