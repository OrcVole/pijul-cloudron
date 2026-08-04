#!/bin/bash
# Run the built image locally against a PostgreSQL sidecar, with the environment
# Cloudron would inject, and assert the things that matter.
#
# The point is a ten-minute cycle that catches defects before anything touches a
# rig. It exists because of one specific class of failure: an upstream whose own
# deployment runs migrations as a superuser bakes assumptions into its SQL that a
# managed addon cannot satisfy, and **a stock postgres sidecar cannot reproduce
# that, because its bootstrap user IS a superuser**.
#
# So this deliberately creates a NOSUPERUSER NOCREATEROLE role and hands the app
# that. Without it the suite would pass while the platform failed.
#
# Usage: test/local-stack.sh [IMAGE] [--keep]
set -uo pipefail

IMAGE="${1:-ghcr.io/orcvole/pijul-cloudron:1.0.0-1}"
KEEP=0
[[ "${2:-}" == "--keep" ]] && KEEP=1

CRI="$(command -v podman || command -v docker)"
NET=pijul-local
PG=pijul-local-pg
APP=pijul-local-app
HOST_PORT=18081
HOST_SSH=12222

PASS=0
FAIL=0

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

check_status() {   # path, expected, why
    local got
    got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:${HOST_PORT}$1")"
    if [[ "$got" == "$2" ]]; then ok "$1 → $got  ($3)"; else bad "$1 → $got, expected $2  ($3)"; fi
}

cleanup() {
    [[ $KEEP -eq 1 ]] && { echo "keeping containers; app on http://127.0.0.1:${HOST_PORT}"; return; }
    $CRI rm -f "$APP" "$PG" >/dev/null 2>&1
    $CRI network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

say "starting PostgreSQL 16, matching the addon's major"
$CRI network create "$NET" >/dev/null 2>&1
$CRI rm -f "$PG" "$APP" >/dev/null 2>&1
$CRI run -d --name "$PG" --network "$NET" \
    -e POSTGRES_PASSWORD=local docker.io/library/postgres:16 >/dev/null || exit 2

until $CRI exec "$PG" pg_isready -q 2>/dev/null; do sleep 1; done

# The whole reason this file exists. An addon-shaped role: owns its database, and
# can create neither roles nor anything requiring superuser.
$CRI exec -i "$PG" psql -U postgres -q -v ON_ERROR_STOP=1 <<'SQL' || exit 2
CREATE ROLE nestapp LOGIN PASSWORD 'local' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE nest OWNER nestapp;
SQL
ok "addon-shaped role created: NOSUPERUSER NOCREATEROLE"

say "starting the app with the environment Cloudron injects"
$CRI run -d --name "$APP" --network "$NET" \
    -p "${HOST_PORT}:8000" -p "${HOST_SSH}:2222" \
    -e CLOUDRON_APP_DOMAIN=pijul.example.com \
    -e CLOUDRON_APP_ORIGIN=https://pijul.example.com \
    -e CLOUDRON_POSTGRESQL_URL="postgres://nestapp:local@${PG}:5432/nest?sslmode=disable" \
    -e CLOUDRON_POSTGRESQL_USERNAME=nestapp \
    -e CLOUDRON_POSTGRESQL_PASSWORD=local \
    -e CLOUDRON_POSTGRESQL_HOST="$PG" \
    -e CLOUDRON_POSTGRESQL_PORT=5432 \
    -e CLOUDRON_POSTGRESQL_DATABASE=nest \
    -e NEST_SSH_PORT="$HOST_SSH" \
    "$IMAGE" >/dev/null || exit 2

say "waiting for the health check path"
for _ in $(seq 1 90); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null)" == "200" ]] && break
    sleep 2
done

say "the path split, which is what a broken change breaks first"
check_status /              200 "UI front page"
check_status /login         405 "API route exists and wants POST"
check_status /register      400 "API route exists"
check_status /theme-init.js 200 "adapter-node serves its own static files"
check_status /fonts/iosevka/IosevkaTerm-Regular.woff2 200 "bundled web font"

say "processes and privileges"
if $CRI exec "$APP" bash -lc 'ss -lntp 2>/dev/null | grep -q ":5000"'; then
    ok "API listening on 5000"
else bad "API not listening on 5000"; fi

if $CRI exec "$APP" bash -lc 'ss -lntp 2>/dev/null | grep -q ":2222"'; then
    ok "SSH listening on 2222"
else bad "SSH not listening on 2222"; fi

if $CRI exec "$APP" bash -lc 'ps -o user= -C nest | grep -qv root'; then
    ok "nest runs as a non-root user"
else bad "nest is running as root"; fi

say "database"
migrations="$($CRI exec "$PG" psql -U postgres -d nest -tAc \
    'SELECT count(*) FROM __diesel_schema_migrations' 2>/dev/null | tr -d ' ')"
if [[ "${migrations:-0}" -ge 28 ]]; then
    ok "$migrations migrations applied by the unprivileged role"
else bad "only ${migrations:-0} migrations applied"; fi

leftover="$($CRI exec "$APP" bash -lc 'grep -rho "TO pijul" /app/code/migrations 2>/dev/null | wc -l' | tr -d ' ')"
if [[ "$leftover" == "0" ]]; then
    ok "no hardcoded pijul grants survive in the image"
else bad "$leftover hardcoded 'TO pijul' grants remain: first boot will fail on a real addon"; fi

say "idempotency, which start.sh depends on for every boot"
if $CRI restart "$APP" >/dev/null 2>&1; then
    for _ in $(seq 1 60); do
        [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null)" == "200" ]] && break
        sleep 2
    done
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HOST_PORT}/")" == "200" ]]; then
        ok "survives a restart with migrations already applied"
    else bad "did not come back after a restart"; fi
fi

say "secrets are generated once and kept"
if $CRI exec "$APP" bash -lc 'test -s /app/data/secrets/pbkdf2_password && test -s /app/data/secrets/pbkdf2_salt && test -s /app/data/secrets/ssh_host_ed25519_key'; then
    ok "PBKDF2 material and SSH host key present"
else bad "secret material missing"; fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
