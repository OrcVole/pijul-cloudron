#!/bin/bash
set -eu -o pipefail

# Pijul Nest entrypoint.
#
# Runs as root, does the work only root can do, then hands every long-running
# process to the unprivileged `cloudron` user through supervisor.

readonly DATA=/app/data
readonly RUN=/run/nest

echo "==> Pijul Nest starting, upstream change $(cat /app/code/.upstream-change)"

# ── Layout ───────────────────────────────────────────────────────────────────
# Re-asserted on EVERY boot, not only the first. A restore or a platform-side
# change can reset ownership, and the API does not warn when it cannot read its
# key material: it panics at config.rs:140 with CouldNotReadKey and crash-loops.
mkdir -p "${DATA}/repositories" "${DATA}/home" "${DATA}/secrets"
mkdir -p "${RUN}/nginx/body" "${RUN}/nginx/proxy" "${RUN}/nginx/fastcgi" \
         "${RUN}/nginx/uwsgi" "${RUN}/nginx/scgi"

# ── Secrets, generated once and never again ──────────────────────────────────
# Upstream's own recipe, from secrets/generate.nix: 32 random bytes, base64.
# The PBKDF2 material must match between the API and the UI, and regenerating it
# locks every existing user out of their account, so this is strictly create-if-absent.
generate_once() {
    local path="$1" what="$2"
    if [[ ! -f "${path}" ]]; then
        echo "==> generating ${what} (first run)"
        dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 -w0 > "${path}"
    else
        echo "==> existing ${what} found, keeping it"
    fi
}

generate_once "${DATA}/secrets/pbkdf2_password" "PBKDF2 password"
generate_once "${DATA}/secrets/pbkdf2_salt"     "PBKDF2 salt"

# The API cats the SMTP password file unconditionally, outside any conditional,
# even with email disabled. It must exist whether or not mail is configured.
if [[ ! -f "${DATA}/secrets/smtp_password" ]]; then
    printf '%s' "${CLOUDRON_MAIL_SMTP_PASSWORD:-unused}" > "${DATA}/secrets/smtp_password"
fi

# The SSH host key. Generated once and kept: regenerating it gives every client a
# host-key-changed warning, which for a version control system reads as an attack.
if [[ ! -f "${DATA}/secrets/ssh_host_ed25519_key" ]]; then
    echo "==> generating the SSH host key (first run)"
    ssh-keygen -t ed25519 -N '' -C 'pijul-nest' -f "${DATA}/secrets/ssh_host_ed25519_key" -q
else
    echo "==> existing SSH host key found, keeping it"
fi

# ── Configuration, rewritten on every boot ───────────────────────────────────
# Addon credentials can change across restarts, so nothing here is cached.
#
# `user` and `group` are deliberately absent. api/src/config.rs drop_privileges()
# is a no-op when both are missing, which is what lets the API run unprivileged.
# Setting them would make it attempt a setuid as the cloudron user and panic on
# .apply().unwrap().
cat > "${RUN}/config.toml" <<EOF
repository_cache_size = 64
change_cache_size     = 64
host                  = "${CLOUDRON_APP_DOMAIN}"
hostname              = "${CLOUDRON_APP_ORIGIN}"
origin                = "${CLOUDRON_APP_ORIGIN}"
repositories_path     = "${DATA}/repositories"
partial_change_size   = 1048576
basic_size_limit      = 100000000000
pro_size_limit        = 100000000000
postgres              = "${CLOUDRON_POSTGRESQL_URL}"

[http]
http_port = 5000

[ssh]
port = 2222

[ci]
url = []
EOF

printf 'repositories = "%s/repositories"\n' "${DATA}" > "${RUN}/replication.toml"

# ── Database ─────────────────────────────────────────────────────────────────
# Migrations run on every boot and are idempotent.
#
# No --locked-schema and no [print_schema] section: --locked-schema is a developer
# guard that regenerates api/src/db.rs and compares it, which at runtime would both
# fail on a diesel-cli formatting difference and try to write into readonly /app/code.
printf '[migrations_directory]\ndir = "/app/code/migrations"\n' > "${RUN}/diesel.toml"

echo "==> running migrations"
DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}" /app/code/bin/diesel migration run \
    --migration-dir /app/code/migrations \
    --config-file "${RUN}/diesel.toml"

# ── nginx ────────────────────────────────────────────────────────────────────
# One public hostname, split by path between the API and the UI. Templated because
# the SSH port is chosen by the operator at install time and shown to the user.
sed -e "s|__SSH_PORT__|${NEST_SSH_PORT:-disabled}|g" \
    /app/code/nginx.conf > "${RUN}/nginx.conf"

# ── Ownership, last, so everything created above is covered ──────────────────
chown -R cloudron:cloudron "${DATA}" "${RUN}"
chmod 700 "${DATA}/secrets"
chmod 600 "${DATA}"/secrets/*

echo "==> handing over to supervisor"
# --configuration, not --configfile: supervisord in cloudron/base:5.0.0 accepts only
# -c/--configuration and errors out on --configfile.
exec /usr/bin/supervisord --configuration /app/code/supervisord.conf --nodaemon
