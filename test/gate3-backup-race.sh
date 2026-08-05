#!/bin/bash
# Gate 3 risk test: does a live Cloudron backup racing a live push corrupt a
# repository? See docs/DEBUGGING.md "Gate 3 risk" for the mechanism: sanakirja's
# commit protocol overwrites one of two fixed root pages in place, serialised
# only by advisory OS locks a filesystem-level backup process has no reason to
# take.
#
# This is PROBABILISTIC. One trial with no corruption is weak evidence ("did
# not hit the window this time"), not proof of safety. Run with as many
# trials as time allows; the script reports how many it ran so that number is
# never silently lost.
#
# Method: for each trial, start `cloudron backup create` in the background,
# then immediately push a new change over SSH while the backup is (probably)
# still walking the filesystem. After all trials, restore from the LAST
# backup taken during a race window and verify the repository is not merely
# present but genuinely openable and its log is internally consistent
# (`pijul log` succeeds, not just `pijul clone`, since a torn root page can
# leave a store that clones but fails to log or check).
#
# Usage: CLOUDRON_HOST=<ssh-alias> test/gate3-backup-race.sh <base-url> <app-fqdn> [trials]
set -uo pipefail

CLOUDRON_HOST="${CLOUDRON_HOST:?set CLOUDRON_HOST to the ssh alias for the rig, e.g. haggis}"
BASE="${1:?usage: gate3-backup-race.sh <base-url> <app-fqdn> [trials]}"
APP="${2:?usage: gate3-backup-race.sh <base-url> <app-fqdn> [trials]}"
TRIALS="${3:-3}"

WORK="$(mktemp -d)"
trap 'podman rm -f gate3-race-agent >/dev/null 2>&1; rm -rf "$WORK"' EXIT

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }

CID="$(ssh "$CLOUDRON_HOST" "docker ps --filter label=fqdn=$APP -q" 2>/dev/null | head -1)"
sql() { printf '%s\n' "$1" | ssh "$CLOUDRON_HOST" "docker exec -i $CID bash -c 'psql \"\$CLOUDRON_POSTGRESQL_URL\" -tA'"; }

say "setup: registered user, SSH key, one repository"
LOGIN="race$$"
PASS="race-test-password-123"
JAR="$WORK/jar"
curl -s -c "$JAR" -X POST "$BASE/register" \
    --data-urlencode "login=$LOGIN" --data-urlencode "email=$LOGIN@example.com" \
    --data-urlencode "pass=$PASS" --data-urlencode "confpass=$PASS" -o /dev/null
user_row="$(sql "SELECT id FROM users WHERE login='${LOGIN}';" | tr -d ' \r')"
raw_b64="$(sql "SELECT encode(t.token,'base64') FROM tokens t WHERE t.user_id='${user_row}';" | tr -d ' \r')"
token="$(printf '%s' "$raw_b64" | tr '+/' '-_')"
token_urlenc="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$token")"
curl -s -c "$JAR" -b "$JAR" "$BASE/register?token=$token_urlenc" -o /dev/null

ssh-keygen -t ed25519 -N '' -C 'gate3-race-test' -f "$WORK/id_ed25519" -q
settings_json="$(curl -s -b "$JAR" -c "$JAR" "$BASE/api/settings")"
csrf_token="$(printf '%s' "$settings_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")"
curl -s -b "$JAR" -c "$JAR" -X POST "$BASE/api/settings/ssh/add" \
    --data-urlencode "key=$(cat "$WORK/id_ed25519.pub")" --data-urlencode "token=$csrf_token" -o /dev/null

REPO="race-repo-$$"
csrf_token="$(curl -s -b "$JAR" -c "$JAR" "$BASE/api/settings" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")"
curl -s -b "$JAR" -c "$JAR" -X POST "$BASE/api/settings/repo/add" \
    --data-urlencode "name=$REPO" --data-urlencode "private=false" --data-urlencode "token=$csrf_token" -o /dev/null

APP_HOST="$(printf '%s' "$BASE" | sed -E 's#https?://##')"
SSH_PORT="$(ssh "$CLOUDRON_HOST" "docker port $CID 2222/tcp" | head -1 | sed -E 's/.*:([0-9]+)$/\1/')"

podman rm -f gate3-race-agent >/dev/null 2>&1
podman run -d --name gate3-race-agent -v "$WORK":/work:Z -v "$WORK":/keys:ro,Z localhost/pijul-toolchain:probe sleep 3600 >/dev/null
# ssh-agent -s prints an `echo Agent pid ...` line alongside the real export
# statements; capturing its whole stdout into a file that gets `.`-sourced
# later makes that line a syntax error ("Agent: command not found"). Keep
# only the two SSH_* export lines.
podman exec gate3-race-agent bash -c \
  'ssh-agent -s | grep "^SSH_" > /tmp/agent-env; . /tmp/agent-env; ssh-add /keys/id_ed25519' >/dev/null 2>&1
AUTH_SOCK="$(podman exec gate3-race-agent bash -c '. /tmp/agent-env >/dev/null; echo $SSH_AUTH_SOCK')"

podman exec -w /work gate3-race-agent bash -c "
export HOME=/tmp
mkdir -p src && cd src
pijul init >/dev/null 2>&1
echo baseline > file.txt
pijul add file.txt >/dev/null 2>&1
"
podman exec -e SSH_AUTH_SOCK="$AUTH_SOCK" -w /work/src gate3-race-agent bash -c "
export HOME=/tmp
mkdir -p /tmp/.ssh
ssh-keyscan -p ${SSH_PORT} -H ${APP_HOST} >> /tmp/.ssh/known_hosts 2>/dev/null
pijul record -a -m baseline >/dev/null 2>&1
script -qefc 'pijul push -a ssh://${LOGIN}@${APP_HOST}:${SSH_PORT}/${LOGIN}/${REPO}' /dev/null <<< y >/dev/null 2>&1
"
ok "baseline commit pushed"

say "racing $TRIALS trial(s): backup create + push, concurrent"
last_race_backup=""
for i in $(seq 1 "$TRIALS"); do
    echo "  trial $i/$TRIALS"
    script -qefc "cloudron backup create --app $APP" /dev/null > "$WORK/backup-$i.log" 2>&1 &
    backup_pid=$!
    podman exec -w /work/src gate3-race-agent bash -c "
        echo 'change $i' >> file.txt
        pijul add file.txt >/dev/null 2>&1
        pijul record -a -m 'race trial $i' >/dev/null 2>&1
    "
    podman exec -e SSH_AUTH_SOCK="$AUTH_SOCK" -w /work/src gate3-race-agent bash -c "
        export HOME=/tmp
        script -qefc 'pijul push -a ssh://${LOGIN}@${APP_HOST}:${SSH_PORT}/${LOGIN}/${REPO}' /dev/null <<< y >/dev/null 2>&1
    "
    wait "$backup_pid"
    if grep -qi "backed up" "$WORK/backup-$i.log"; then
        # Match the id pattern rather than a fixed line number: `script`'s pty
        # wrapper inserts a leading blank line, which silently shifted this by
        # one and made an earlier version of this script capture the literal
        # header text "Id" as if it were a real backup id.
        last_race_backup="$(script -qefc "cloudron backup list --app $APP" /dev/null 2>/dev/null \
            | grep -oE '^app_[A-Za-z0-9_-]+' | head -1)"
        echo "    backup finished during/around the push (id: ${last_race_backup:-unknown})"
    else
        echo "    backup did not report success this trial:"
        tail -3 "$WORK/backup-$i.log" | sed 's/^/      /'
    fi
done

if [[ -z "$last_race_backup" ]]; then
    bad "no backup completed successfully across $TRIALS trial(s); cannot test restore"
    exit 1
fi

say "restore from the last race-window backup and check the repository, not just its presence"
script -qefc "cloudron restore --app $APP --backup $last_race_backup" /dev/null > "$WORK/restore.log" 2>&1
if ! grep -qi "restored" "$WORK/restore.log"; then
    bad "restore did not report success:"
    tail -5 "$WORK/restore.log" | sed 's/^/  /'
    exit 1
fi
ok "restore completed"

NEW_CID="$(ssh "$CLOUDRON_HOST" "docker ps --filter label=fqdn=$APP -q" 2>/dev/null | head -1)"
for _ in $(seq 1 30); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/" 2>/dev/null)" == "200" ]] && break
    sleep 2
done

# The real test: clone succeeding proves the store opens. `pijul log` succeeding
# proves the change graph is internally consistent, which a torn root page can
# break even when a plain clone appears to work.
clone_out="$(podman exec -w /work gate3-race-agent bash -c "
    export HOME=/tmp
    rm -rf /work/verify
    pijul clone https://${APP_HOST}/${LOGIN}/${REPO} /work/verify 2>&1
")"
log_out="$(podman exec -w /work/verify gate3-race-agent bash -c 'export HOME=/tmp; pijul log 2>&1')"

if printf '%s' "$clone_out" | grep -qi "Repository created" && \
   printf '%s' "$log_out" | grep -qi "^Change "; then
    ok "post-restore repository opens and its log is internally consistent"
    printf '%s\n' "$log_out" | grep -c "^Change " | xargs -I{} echo "  {} change(s) visible in the restored log"
else
    bad "post-restore repository failed to open or log cleanly -- this IS the risk this test exists to catch"
    echo "--- clone output ---"; printf '%s\n' "$clone_out" | sed 's/^/  /'
    echo "--- log output ---"; printf '%s\n' "$log_out" | sed 's/^/  /'
    exit 1
fi

printf '\n%d trial(s) run. A pass here means the window was not hit in %d tries, not that the risk is closed.\n' "$TRIALS" "$TRIALS"
