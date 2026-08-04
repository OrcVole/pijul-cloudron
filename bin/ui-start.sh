#!/bin/bash
set -eu -o pipefail

# The SvelteKit front end under node. Mirrors upstream's ui-start wrapper.
#
# The PBKDF2 values MUST be byte-identical to the ones the API reads. Upstream says
# so in as many words, and they are read from the same files here for that reason.

export PBKDF2_PASSWORD="$(cat /app/data/secrets/pbkdf2_password)"
export PBKDF2_SALT="$(cat /app/data/secrets/pbkdf2_salt)"
export PBKDF2_ITERATIONS=600000

export DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}"
export NEST_API_INTERNAL="http://127.0.0.1:5000"
export HOST=127.0.0.1
export PORT=5050
export ORIGIN="${CLOUDRON_APP_ORIGIN}"

# Mail. The sendmail addon injects these; the UI reads its own names.
if [[ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]]; then
    export SMTP_HOST="${CLOUDRON_MAIL_SMTP_SERVER}"
    export SMTP_PORT="${CLOUDRON_MAIL_SMTP_PORT}"
    export SMTP_USER="${CLOUDRON_MAIL_SMTP_USERNAME}"
    export SMTP_PASS="${CLOUDRON_MAIL_SMTP_PASSWORD}"
    export EMAIL_FROM="${CLOUDRON_MAIL_FROM}"
fi

# Quotas. freePrivateRepos defaults to 0 upstream, which is a hosted-service default:
# on a self-hosted instance it would give every user no private repositories at all
# and read as a bug. The others are set to the same generous value for the same reason,
# since there is no paid tier here to distinguish.
export FREE_PRIVATE_REPOS="${NEST_PRIVATE_REPOS:-1000}"
export PRO_PRIVATE_REPOS="${NEST_PRIVATE_REPOS:-1000}"
export FREE_STORAGE_BYTES="${NEST_STORAGE_BYTES:-107374182400}"
export PRO_STORAGE_BYTES="${NEST_STORAGE_BYTES:-107374182400}"

# Not exported at all, which is how they are disabled:
#   PUBLIC_JOBS_ENABLED  - CI. Only set when ci.url or ci.filesystem is configured.
#   STRIPE_*             - billing. The module's own words: "Set to null to disable billing."
#   ZULIP_API_KEY        - notifications.

exec /usr/local/node-22.14.0/bin/node /app/code/ui
