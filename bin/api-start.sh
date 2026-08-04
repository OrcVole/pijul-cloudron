#!/bin/bash
set -eu -o pipefail

# The API. Mirrors upstream's api-start wrapper in nest.nix.
#
# Every one of these is an .expect() or .unwrap() in api/src/config.rs, so a missing
# or unreadable value is a panic and a crash loop rather than a degraded start.
# ssh_secret is the key CONTENT, not a path to it.

export ssh_secret="$(cat /app/data/secrets/ssh_host_ed25519_key)"
export PBKDF2_PASSWORD="$(cat /app/data/secrets/pbkdf2_password)"
export PBKDF2_SALT="$(cat /app/data/secrets/pbkdf2_salt)"
export PBKDF2_ITERATIONS=600000
export SMTP_PASSWORD="$(cat /app/data/secrets/smtp_password)"

export DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}"
export RUST_LOG="${NEST_RUST_LOG:-nest=info}"
export TERM=vt100

# exec so the binary becomes the process supervisor signals directly. Without it
# SIGTERM hits this shell, which does not forward it, and the API is orphaned still
# holding its listening ports.
exec /app/code/bin/nest \
    --config /run/nest/config.toml \
    --replication /run/nest/replication.toml
