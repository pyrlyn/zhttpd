#!/usr/bin/env bash
# Self-signed ECDSA P-256 certificate for localhost, used by smoke tests and benchmarks.
# The private key stays in bench/certs/ which is git-ignored: never commit it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENSSL="${OPENSSL_BIN:-$ROOT/deps/openssl-install/bin/openssl}"
[ -x "$OPENSSL" ] || { echo "run mise run deps:tls first" >&2; exit 1; }
# the static OpenSSL build installs no openssl.cnf; use the one from its source tree
for cnf in "$ROOT"/deps/openssl-*/apps/openssl.cnf; do [ -f "$cnf" ] && export OPENSSL_CONF="$cnf"; done
mkdir -p "$ROOT/bench/certs"
cd "$ROOT/bench/certs"
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout key.pem -out cert.pem
chmod 600 key.pem
printf '*\n!.gitignore\n' > .gitignore
echo "wrote $PWD/cert.pem and key.pem (git-ignored)"
