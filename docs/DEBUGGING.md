# Debugging and gate evidence

Invariant tables with a proof cell. An entry here carries enough of the recipe to repeat it at the
next version bump, and a claim with no proof is written as a claim.

## Ports and processes

| What | Where | Proof |
| --- | --- | --- |
| nginx, the only thing Cloudron talks to | `:8000` | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/` returns 200 |
| the API, HTTP | `127.0.0.1:5000` | `ss -lntp` shows `nest` holding it |
| the API, SSH | `0.0.0.0:2222`, mapped by `tcpPorts` | `ssh -p <port> nest@<domain>` banners `thrussh_0.41.0` |
| the UI under node | `127.0.0.1:5050` | `ss -lntp` shows `node` holding it |
| `nest-rank` | no port | log line `==> nest-rank starting` every six hours |

## The path split, which is the thing most likely to be broken by a change

Run these against the app's own domain. `/login` returning 200 or 404 rather than 405 means the
split has broken and signing in is impossible.

| Path | Expected | Served by |
| --- | --- | --- |
| `/` | 200 | UI |
| `/login` (GET) | **405** | API |
| `/register` (GET) | **400** | API |
| `/api/` | 404 | API |
| `/theme-init.js` | 200 | UI |
| `/fonts/iosevka/IosevkaTerm-Regular.woff2` | 200 `font/woff2` | UI |

```bash
for p in / /login /register /api/ /theme-init.js; do
  printf '%-16s ' "$p"
  curl -s -o /dev/null -w '%{http_code}\n' "https://<domain>$p"
done
```

## Verified during phase 1, on a local stand-up

| Invariant | Proof |
| --- | --- |
| API runs unprivileged | `LISTEN *:2222` and `LISTEN *:5000` both `users:(("nest",pid=1))` while `id -u` is 1000, and **no "Dropping privileges" line** in the log |
| No etcd | nothing listening on 2379 anywhere reachable; `podman logs nest-api \| grep -ci etcd` returns 0 |
| Runtime needs no apt packages | `ldd nest` against a **bare** `cloudron/base:5.0.0` resolves every entry |
| Migrations apply unprivileged | 28 rows in `__diesel_schema_migrations`, 30 tables, run as a `NOSUPERUSER NOCREATEROLE` role |
| Migrations are idempotent | second `diesel migration run` exits 0 with no output |
| Trusted extensions create unprivileged | `citext`, `pg_trgm`, `pgcrypto` all `CREATE EXTENSION` as owner **and** as a non-owner holding only `CREATE` |
| Fonts served without an nginx alias | all 8 declared faces 200 `font/woff2` from `ui/static` through the proxy |

## Failure modes seen, and what they actually were

**`role "pijul" does not exist` on first boot.** The build-time migration rewrite did not run or did
not match. Check `grep -rho 'TO pijul' /app/code/migrations | wc -l` inside the container: it must be
0. The Dockerfile asserts this, so a non-zero count means the assertion was removed.

**API crash-looping with `CouldNotReadKey`.** It cannot read
`/app/data/secrets/ssh_host_ed25519_key`. Almost always ownership: `start.sh` chowns `/app/data` on
every boot, so this means either the chown was skipped or the file was created by the wrong user. The
API panics rather than warning, so there is no gentler symptom to look for.

**502 from nginx while the app is fine.** Seen during the local stand-up after restarting the UI
container: nginx had cached the old upstream IP. **Isolate before believing it** by asking the
upstream directly, bypassing nginx. Inside the real container everything is on 127.0.0.1, so this
particular cause cannot occur, but the habit is the point.

**A build reported as succeeding when it failed.** `podman build ... | tail -N` reports `tail`'s exit
status, not the build's. Take the verdict from `podman images`, or use `PIPESTATUS`.

**nginx crash-looped, app answered nothing on `:8000` (found in `1.0.0-1`).** `supervisor/nest.conf`
started nginx with `-g "daemon off;"` while `nginx.conf` itself already set `daemon off;`. nginx
rejects the directive given both ways:

```
nginx: [emerg] "daemon" directive is duplicate in /run/nest/nginx.conf:15
```

supervisor restarted it four times in seven seconds and gave up: `nginx entered FATAL state, too many
start retries too quickly`. Every other process (`nest-api`, `nest-ui`, `nest-rank`) started fine, so
this was invisible to anything checking only that the container was `Up` and invisible to `cloudron
exec` returning happily; only an actual request against port 8000 (or reading the supervisor log)
showed it. Fixed by dropping `-g "daemon off;"` from the command line, since the file directive is the
one documented as deliberate. `test/local-stack.sh` caught it immediately: all five path-split checks
failed with `000` (connection refused), which is what a fully-dead front proxy looks like, as distinct
from a wrong response code.

## Browser rendering: worked, but not the obvious way

**`--dump-dom` and `--screenshot` hang against this application.** Three routes tried and all hung
with no error: playwright's bundled chromium, `chrome-headless-shell`, and a containerised
`alpine-chrome`, every one of them using Chrome's own CLI flags. `about:blank` and other static pages
render instantly with the same binary, so the browser itself was never the problem.

**Diagnosis:** the page opens a persistent SSE (server-sent events) connection — `grep -oi sse` on
the served bundle finds it. Chrome's CLI screenshot flags wait for the page's `load` event by
default, and a long-lived connection opened during page setup appears to prevent that event from
being considered settled in headless mode, even though the DOM itself is long since fully rendered.

**Fix: drive navigation manually over the DevTools Protocol with a fixed wait instead of trusting the
browser's own load-event heuristic.** `test/support/cdp-screenshot.py`:

1. Launch Chrome once with `--remote-debugging-port` and leave it running.
2. `PUT /json/new?<url>` to open a tab (note **PUT**, not GET — Chrome 149 returns 405 on GET).
3. `Page.navigate` over the WebSocket, wait a **fixed** few seconds rather than for a load event.
4. `Page.captureScreenshot`.

Verified working: `phase-notes/standup-frontpage.png` is a full, correctly rendered login page —
Iosevka Term loading, the brand wordmark matching `logo.png`, live data from the database ("1
registered user"). This is gate 0's rendering step, and it is the reason the check has to actually be
looked at rather than trusted from a 200 status code and a DOM dump: everything upstream of this
point already reported success.

## Registration and email confirmation, read from source ahead of gate 2

**`/register` is one route serving two purposes**, split by HTTP method:

- `POST /register` (`auth::register_post`) creates the user row with `email_is_invalid = true`,
  inserts a random 32-byte token into the `tokens` table, and sends a confirmation email. **If the
  email send fails, the user row is deleted** and the response is the generic `?error=alreadyExists`,
  which is indistinguishable from a real conflict. A broken `sendmail` addon wiring therefore looks
  like every registration silently failing with no diagnostic beyond the API log.
- `GET /register?token=<base64url>` (`auth::register_get`) is the confirmation link: it looks the
  token up in the `tokens` table, deletes it, sets `email_is_invalid` to `NULL`, and signs the user in.

**This is why `GET /register` with no query string returns 400, not a page.** `RegisterToken.token` is
a required `String`, so Axum's `Query` extractor rejects the request before the handler runs. This was
observed and correctly asserted in `test/local-stack.sh` without this explanation; now it has one.

**For gate 2, the confirmation token does not need a live inbox.** The `tokens` table stores the raw
32 bytes; only the emailed link is base64url-encoded. Read it straight from the database:

```sql
SELECT encode(t.token, 'base64') FROM tokens t
  JOIN users u ON u.id = t.user_id WHERE u.login = '<test-login>';
```

(convert standard base64 to base64**url** — `+`→`-`, `/`→`_`, strip `=` padding — since the column
is raw bytes and the route decodes with `BASE64URL`), then `GET /register?token=<that>` and confirm
`email_is_invalid` is `NULL` afterwards. This exercises the `sendmail` addon's wiring (the send must
have succeeded for the row to survive) without needing to receive real mail.

## Gate ladder

Not yet run past gate 0's rendering step. Gates 1 to 4 execute against the shipping digest and their
evidence lands here.
