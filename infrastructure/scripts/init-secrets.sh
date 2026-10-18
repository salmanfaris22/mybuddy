#!/usr/bin/env bash
# Generates ./secrets for docker-compose.yml: the Postgres password and URL, the TURN shared secret
# and the rendered coturn config. It never prints a secret and never passes one as a command-line
# argument (only shell builtins and environment variables touch them).
#
#   scripts/init-secrets.sh <public IPv4 of this server>
#
# Refuses to overwrite existing secrets: rotating is deliberate (see README, "Rotating secrets").
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PUBLIC_IP="${1:-}"
if [[ ! "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "usage: scripts/init-secrets.sh <public IPv4 of this server>" >&2
  exit 2
fi
if [[ ! -f .env ]]; then
  echo "Create .env from .env.example first." >&2
  exit 1
fi
MYBUDDY_TURN_HOST="$(grep -E '^MYBUDDY_TURN_HOST=' .env | tail -1 | cut -d= -f2-)"
if [[ -z "$MYBUDDY_TURN_HOST" ]]; then
  echo "Set MYBUDDY_TURN_HOST in .env." >&2
  exit 1
fi
if [[ -e secrets ]]; then
  echo "secrets/ already exists. Move it away deliberately to rotate; nothing was changed." >&2
  exit 1
fi
command -v openssl >/dev/null || { echo "openssl is required." >&2; exit 1; }

umask 077
mkdir secrets
# 48 random alphanumeric characters (~285 bits): safe inside URLs and config files without escaping.
random_secret() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 48; }
DB_PASSWORD="$(random_secret)"
TURN_SECRET="$(random_secret)"
[[ ${#DB_PASSWORD} -eq 48 && ${#TURN_SECRET} -eq 48 ]] || { echo "Could not generate secrets." >&2; exit 1; }

printf '%s' "$DB_PASSWORD" > secrets/db_password
printf 'postgres://mybuddy:%s@postgres:5432/mybuddy?sslmode=disable' "$DB_PASSWORD" > secrets/database_url
printf '%s' "$TURN_SECRET" > secrets/turn_secret
TURN_SECRET="$TURN_SECRET" TURN_REALM="$MYBUDDY_TURN_HOST" PUBLIC_IP="$PUBLIC_IP" awk '{
  gsub(/__TURN_SECRET__/, ENVIRON["TURN_SECRET"]); gsub(/__TURN_REALM__/, ENVIRON["TURN_REALM"]); gsub(/__PUBLIC_IP__/, ENVIRON["PUBLIC_IP"]); print
}' coturn/turnserver.conf.example > secrets/turnserver.conf
unset DB_PASSWORD TURN_SECRET

# The directory stays 0700 so other host users cannot reach the files. The files themselves are
# 0644 because Compose bind-mounts them unchanged and the containers run as non-root users
# (distroless "nonroot", coturn "nobody") that must be able to read them.
chmod 700 secrets
chmod 644 secrets/*
echo "Created secrets/ (db_password, database_url, turn_secret, turnserver.conf). Values were not printed."
echo "Next: docker compose up -d --build"
