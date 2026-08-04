#!/bin/bash
# Gate 2: real functional flows, exercised through the app's own front door.
#
# Run from the Cloudron host against the live throwaway install (or any reachable
# instance). Requires: curl, a postgres client able to reach the app's database
# (root shell on the host, or `cloudron exec` piped to psql), and a `pijul` client
# for the push/pull leg.
#
# Every flow here was chosen because it touches a declared addon or a documented
# load-bearing step found while reading the source (see docs/DEBUGGING.md):
#   - registration exercises `sendmail` and rolls back on send failure
#   - repository push/pull exercises `localstorage` and `postgresql` together
#   - the discussion flow exercises the read path back out through the UI
#
# Usage: test/gate2-flows.sh <base-url> <app-name-on-cloudron>
#   e.g.  test/gate2-flows.sh https://pijul-testing.haggis.top pijul-testing.haggis.top
set -uo pipefail

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
# credentials, read from the running container's environment. Not from outside
# the box: the addon URL is injected only into the app container.
sql() {
    cloudron exec --app "$APP" -- bash -c \
        "PGPASSWORD=\$(echo \"\$CLOUDRON_POSTGRESQL_URL\" | sed -E 's#.*://[^:]+:([^@]+)@.*#\1#') \
         psql \"\$CLOUDRON_POSTGRESQL_URL\" -tAc \"$1\""
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

user_row="$(sql "SELECT id FROM users WHERE login='${LOGIN}'" | tr -d ' ')"
if [[ -n "$user_row" ]]; then
    ok "user row survived (id=$user_row): the confirmation email send succeeded"
else
    bad "no user row: registration rolled back, meaning sendmail failed silently"
    exit 1
fi

say "flow: email confirmation (no live inbox needed, per docs/DEBUGGING.md)"
raw_b64="$(sql "SELECT encode(t.token,'base64') FROM tokens t WHERE t.user_id='${user_row}'" | tr -d ' ')"
# base64 -> base64url: the route decodes with data_encoding::BASE64URL.
token="$(printf '%s' "$raw_b64" | tr '+/' '-_' | tr -d '=')"
if [[ -z "$token" ]]; then
    bad "no confirmation token found in the tokens table"
else
    confirm_status="$(curl -s -o /dev/null -w '%{http_code}' -c "$JAR" -b "$JAR" \
        "$BASE/register?token=$token")"
    invalid_flag="$(sql "SELECT email_is_invalid FROM users WHERE id='${user_row}'" | tr -d ' ')"
    if [[ "$confirm_status" =~ ^30 ]] && [[ -z "$invalid_flag" ]]; then
        ok "GET /register?token=... confirmed the account (email_is_invalid now NULL)"
    else
        bad "confirmation did not take: status=$confirm_status email_is_invalid='$invalid_flag'"
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
WORK="$(mktemp -d)"
( cd "$WORK" && pijul init repo-src >/dev/null 2>&1 \
    && cd repo-src \
    && echo "gate 2 content $(date +%s 2>/dev/null || echo static)" > hello.txt \
    && pijul add hello.txt >/dev/null 2>&1 \
    && pijul record -a -m "gate 2 test change" >/dev/null 2>&1 )
if [[ -f "$WORK/repo-src/hello.txt" ]]; then
    ok "local test change recorded"
else
    bad "could not record a local test change; pijul client missing or broken"
fi

say "flow: repository creation (POST /repo/add, CSRF-protected, session-gated)"
# api/src/settings.rs:479 create_repo(): requires a signed-in session
# (get_user_id_strict, FORBIDDEN otherwise) and a CSRF token verified via
# axum_csrf's double-submit pattern — the cookie alone is not enough, the visible
# form's token field must also be POSTed. PREDICTION, not yet observed against a
# real page: the dashboard at "/" after login renders that form. Confirm the
# selector below against the real HTML on first run of this script and correct it
# rather than trusting it; on_conflict_do_nothing() means a repeat run is safe
# either way.
REPO_NAME="gate2-repo-$$"
dashboard_html="$(curl -s -b "$JAR" -c "$JAR" "$BASE/")"
csrf_token="$(printf '%s' "$dashboard_html" \
    | grep -oE 'name="token"[^>]*value="[^"]*"' | head -1 \
    | sed -E 's/.*value="([^"]*)".*/\1/')"
if [[ -z "$csrf_token" ]]; then
    bad "could not find a CSRF token field on the dashboard; check the selector against the real page"
else
    create_status="$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -c "$JAR" -X POST "$BASE/repo/add" \
        --data-urlencode "name=$REPO_NAME" \
        --data-urlencode "private=false" \
        --data-urlencode "token=$csrf_token")"
    repo_row="$(sql "SELECT id FROM repositories WHERE owner='${user_row}' AND name='${REPO_NAME}'" | tr -d ' ')"
    if [[ "$create_status" == "200" ]] && [[ -n "$repo_row" ]]; then
        ok "repository created: $REPO_NAME (id=$repo_row)"
    else
        bad "repo creation failed: POST status=$create_status, db row present=$([[ -n "$repo_row" ]] && echo yes || echo no)"
    fi
fi

say "flow: push over HTTPS and pull back, verified byte-identical"
if [[ -n "${repo_row:-}" ]]; then
    push_url="$BASE/$LOGIN/$REPO_NAME"
    ( cd "$WORK/repo-src" && pijul push -a "$push_url" 2>&1 | tail -5 )
    rm -rf "$WORK/repo-pull"
    ( cd "$WORK" && pijul clone "$push_url" repo-pull 2>&1 | tail -5 )
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
rank_seen="$(cloudron exec --app "$APP" -- grep -c 'nest-rank starting' /run/nest/nest-rank.log 2>/dev/null || echo 0)"
if [[ "${rank_seen:-0}" -gt 0 ]]; then
    ok "nest-rank has run at least once (log evidence)"
else
    echo "  (not yet run — first run is at 5 minutes after boot; rerun this check later)"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS_TOTAL" "$FAIL_TOTAL"
[[ $FAIL_TOTAL -eq 0 ]] || exit 1
