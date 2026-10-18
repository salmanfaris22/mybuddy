#!/usr/bin/env bash
# Runs the PostgreSQL store contract tests against a throw-away cluster.
# It never touches any existing PostgreSQL server: a fresh cluster is created in
# a temporary directory, bound to a Unix socket only (no TCP), and deleted after.
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for bin in initdb pg_ctl createdb; do
  command -v "$bin" >/dev/null || { echo "not run — $bin not found (install PostgreSQL)"; exit 2; }
done

WORK="$(mktemp -d -t mybuddy-pg-XXXXXX)"
DATA="$WORK/data"
SOCK="$WORK/sock"
mkdir -p "$SOCK"
cleanup() {
  pg_ctl -D "$DATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

initdb -D "$DATA" -U mybuddy --auth=trust --no-instructions >/dev/null
pg_ctl -D "$DATA" -l "$WORK/postgres.log" -w \
  -o "-c listen_addresses='' -c unix_socket_directories='$SOCK' -c fsync=off" start >/dev/null
createdb -h "$SOCK" -U mybuddy mybuddy_test

export MYBUDDY_TEST_DATABASE_URL="postgres://mybuddy@/mybuddy_test?host=$SOCK&sslmode=disable"
cd "$SERVICE_DIR"
go test -count=1 -run 'TestPostgresStoreContract' -v ./internal/store/... "$@"
