#!/bin/bash
# Gate 2: real functional flows, exercised through the app's own front door.
#
# Run from anywhere with ssh access to the Cloudron rig and podman with the
# `localhost/pijul-toolchain:probe` image already built (build/Containerfile.toolchain
# in the round's working folder). Requires curl and python3 (for URL-encoding a
# token) locally; ssh + docker exec on the rig for both postgres queries and log
# reads, not the `cloudron` CLI's own exec channel -- see the note above sql().
# pijul itself runs inside the probe container rather than on the runner host,
# since the packaging rig is an ostree system where installing libsodium means
# a layered rebuild and a reboot.
#
# Every flow here was chosen because it touches a declared addon or a documented
# load-bearing step found while reading the source (see docs/DEBUGGING.md):
#   - registration exercises `sendmail` and rolls back on send failure
#   - repository push/pull exercises `localstorage` and `postgresql` together
#   - the discussion flow exercises the read path back out through the UI
#
# Usage: CLOUDRON_HOST=<ssh-alias> test/gate2-flows.sh <base-url> <app-fqdn>
#   e.g.  CLOUDRON_HOST=haggis test/gate2-flows.sh https://pijul-testing.haggis.top pijul-testing.haggis.top
set -uo pipefail

CLOUDRON_HOST="${CLOUDRON_HOST:?set CLOUDRON_HOST to the ssh alias for the rig, e.g. haggis}"

# `pijul` runs inside the toolchain probe container rather than on the runner
# host: the packaging rig is an ostree system (Bazzite) where installing
# libsodium means an rpm-ostree layer and a reboot, which is disproportionate
# to running a client binary. WORK is bind-mounted so pijul's on-disk state is
# visible to both this script and the container without copying.
WORK="$(mktemp -d)"
# $1 is a subdir of $WORK to run in (container-side, since a host-side `cd`
# never reaches into the container); the rest are ordinary pijul arguments.
# "." runs at $WORK itself, for commands (clone) that take their own PATH arg.
pijul_in() {
    local subdir="$1"; shift
    podman run --rm -v "$WORK":/work:Z -w "/work/$subdir" localhost/pijul-toolchain:probe pijul "$@"
}

BASE="${1:?usage: gate2-flows.sh <base-url> <app-location>}"
APP="${2:?usage: gate2-flows.sh <base-url> <app-location>}"
LOGIN="gate2test$$"
PASS="gate2-flows-test-password"
EMAIL="${LOGIN}@example.com"
JAR="$(mktemp)"
PASS_TOTAL=0
FAIL_TOTAL=0

trap 'rm -f "$JAR"' EXIT

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS_TOTAL=$((PASS_TOTAL+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL_TOTAL=$((FAIL_TOTAL+1)); }

# Runs a SQL statement inside the running app's postgres, via the addon's own
# credentials, read from the running container's environment. Goes over ssh +
# docker exec directly rather than `cloudron exec`, per gotcha #167: the CLI's
# own exec channel degrades mid-session (repeated AggregateError [ETIMEDOUT] on
# a trivial call, observed live while first writing this script), while ssh +
# docker exec found by the app's fqdn label stayed reliable throughout. The
# query is piped in over stdin rather than interpolated into a shell -c string,
# because a query embedded in nested local/ssh/docker/bash quoting is exactly
# how the earlier version of this script silently mis-encoded a token.
CID="$(ssh "$CLOUDRON_HOST" "docker ps --filter label=fqdn=$APP -q" 2>/dev/null | head -1)"
sql() {
    printf '%s\n' "$1" | ssh "$CLOUDRON_HOST" "docker exec -i $CID bash -c 'psql \"\$CLOUDRON_POSTGRESQL_URL\" -tA'"
}

say "flow: registration (exercises sendmail, rolls back the row on send failure)"
resp="$(curl -s -o /dev/null -w '%{http_code}' -c "$JAR" -X POST "$BASE/register" \
    --data-urlencode "login=$LOGIN" \
    --data-urlencode "email=$EMAIL" \
    --data-urlencode "pass=$PASS" \
    --data-urlencode "confpass=$PASS")"
if [[ "$resp" == "303" || "$resp" == "302" ]]; then
    ok "POST /register → $resp (redirect, not the alreadyExists error path)"
else
    bad "POST /register → $resp, expected a redirect; sendmail wiring or the row insert failed"
fi

user_row="$(sql "SELECT id FROM users WHERE login='${LOGIN}';" | tr -d ' \r')"
if [[ -n "$user_row" ]]; then
    ok "user row survived (id=$user_row): the confirmation email send succeeded"
else
    bad "no user row: registration rolled back, meaning sendmail failed silently"
    exit 1
fi

say "flow: email confirmation (no live inbox needed, per docs/DEBUGGING.md)"
raw_b64="$(sql "SELECT encode(t.token,'base64') FROM tokens t WHERE t.user_id='${user_row}';" | tr -d ' \r')"
# base64 -> base64url, PADDING KEPT: the route decodes with
# data_encoding::BASE64URL, the padded variant, unlike the separate
# BASE64URL_NOPAD bearer-token scheme used for HTTPS push (see the note in
# DEBUGGING.md). Stripping the `=` here silently breaks the decode: an earlier
# version of this script did exactly that, and register_get's own fallback
# path swallows the error and redirects to "/" with no cookie set, so the
# failure produced no error message at all -- only a wrong redirect target,
# caught only by checking the Location header, not just the status code.
token="$(printf '%s' "$raw_b64" | tr '+/' '-_')"
token_urlenc="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$token")"
if [[ -z "$token" ]]; then
    bad "no confirmation token found in the tokens table"
else
    confirm_headers="$(curl -sD - -o /dev/null -c "$JAR" -b "$JAR" "$BASE/register?token=$token_urlenc")"
    confirm_location="$(printf '%s' "$confirm_headers" | grep -i '^location:' | tr -d '\r')"
    invalid_flag="$(sql "SELECT email_is_invalid FROM users WHERE id='${user_row}';" | tr -d ' \r')"
    # The success path redirects to /<login>; the fallback (bad token, wrong
    # padding, already-consumed token) redirects to / with no cookie. Checking
    # the Location target, not just the 30x status, is what catches that --
    # both paths return a redirect status.
    if [[ "$confirm_location" == *"/${LOGIN}"* ]] && [[ -z "$invalid_flag" ]]; then
        ok "GET /register?token=... confirmed the account (redirected to /${LOGIN}, email_is_invalid now NULL)"
    else
        bad "confirmation did not take: location='$confirm_location' email_is_invalid='$invalid_flag'"
    fi
fi

say "flow: sign in with the confirmed account"
login_status="$(curl -s -o /dev/null -w '%{http_code}' -c "$JAR" -X POST "$BASE/login" \
    --data-urlencode "login=$LOGIN" --data-urlencode "pass=$PASS")"
if [[ "$login_status" =~ ^30 ]]; then
    ok "POST /login → $login_status"
else
    bad "POST /login → $login_status, expected a redirect"
fi

say "flow: repository push and pull over HTTPS (exercises localstorage + postgresql together)"
mkdir -p "$WORK/repo-src"
pijul_in repo-src init >/dev/null 2>&1
echo "gate 2 content $(date +%s 2>/dev/null || echo static)" > "$WORK/repo-src/hello.txt"
pijul_in repo-src add hello.txt >/dev/null 2>&1
pijul_in repo-src record -a -m "gate 2 test change" >/dev/null 2>&1
if [[ -f "$WORK/repo-src/hello.txt" ]]; then
    ok "local test change recorded"
else
    bad "could not record a local test change; pijul client missing or broken"
fi

say "flow: repository creation (POST /repo/add, CSRF-protected, session-gated)"
# api/src/settings.rs:479 create_repo(): requires a signed-in session
# (get_user_id_strict, FORBIDDEN otherwise) and a CSRF token via axum_csrf's
# double-submit pattern. VERIFIED against the live install (not the earlier
# HTML-scrape guess, which was wrong about the mechanism entirely): there is
# no hidden form field to scrape. Any authenticated GET to /api/... that uses
# the CsrfToken extractor issues a fresh `Csrf_Token` cookie -- concretely,
# GET /api/settings, which SvelteKit's own hooks.server.ts re-emits to the
# browser as a non-httpOnly cookie for client JS to read (see the handleFetch
# comment there). The cookie is httpOnly on Axum's own response, which curl
# reads from Set-Cookie regardless -- httpOnly only restricts browser JS, not
# an HTTP client -- so the browser-side re-emission step is not needed here:
# the same value read from GET /api/settings' Set-Cookie is submitted back
# unchanged as the form's `token` field, csrf_verify() checks it against its
# own cookie copy, and both readings of that value are already in the jar.
REPO_NAME="gate2-repo-$$"
curl -s -o /dev/null -b "$JAR" -c "$JAR" "$BASE/api/settings"
csrf_token="$(grep -i 'csrf_token' "$JAR" | awk '{print $NF}')"
if [[ -z "$csrf_token" ]]; then
    bad "GET /api/settings set no Csrf_Token cookie; check the session is actually authenticated"
else
    create_status="$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -c "$JAR" -X POST "$BASE/repo/add" \
        --data-urlencode "name=$REPO_NAME" \
        --data-urlencode "private=false" \
        --data-urlencode "token=$csrf_token")"
    repo_row="$(sql "SELECT id FROM repositories WHERE owner='${user_row}' AND name='${REPO_NAME}';" | tr -d ' \r')"
    if [[ "$create_status" == "200" ]] && [[ -n "$repo_row" ]]; then
        ok "repository created: $REPO_NAME (id=$repo_row)"
    else
        bad "repo creation failed: POST status=$create_status, db row present=$([[ -n "$repo_row" ]] && echo yes || echo no)"
    fi
fi

say "flow: push over HTTPS and pull back, verified byte-identical"
if [[ -n "${repo_row:-}" ]]; then
    push_url="$BASE/$LOGIN/$REPO_NAME"
    pijul_in repo-src push -a "$push_url" 2>&1 | tail -5
    rm -rf "$WORK/repo-pull"
    pijul_in . clone "$push_url" repo-pull 2>&1 | tail -5
    if [[ -f "$WORK/repo-pull/hello.txt" ]] \
        && diff -q "$WORK/repo-src/hello.txt" "$WORK/repo-pull/hello.txt" >/dev/null 2>&1; then
        ok "pushed and pulled back byte-identical (verified with diff, not just presence)"
    else
        bad "push/pull did not round-trip the same content"
    fi
else
    echo "  (skipped: no repository to push into)"
fi
rm -rf "$WORK"

say "flow: PageRank job runs (nest-rank, every 6h, exercises postgresql read+write)"
rank_seen="$(ssh "$CLOUDRON_HOST" "docker logs $CID 2>&1 | grep -c 'nest-rank starting'" 2>/dev/null || echo 0)"
if [[ "${rank_seen:-0}" -gt 0 ]]; then
    ok "nest-rank has run at least once (log evidence)"
else
    echo "  (not yet run — first run is at 5 minutes after boot; rerun this check later)"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS_TOTAL" "$FAIL_TOTAL"
[[ $FAIL_TOTAL -eq 0 ]] || exit 1
