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

## Gate 0: PASS, against `pijul-testing.haggis.top`

Run 2026-08-05. `1.0.0-1` (on-server build) failed silently on this exact gate — see "nginx crash-looped"
below — which is why the digest and the fix both matter here, not just the final green result.

| Invariant | Proof |
| --- | --- |
| digest | `1.0.0-1`: on-server build, `sha256:584e563b...dc8a6`. `1.0.0-2`: local build, transferred by `docker save \| ssh \| docker load` (no registry push), `sha256:899f4a14...b72e1` |
| install | `cloudron list` → `running`; front page `200` from outside the rig, both independently confirmed |
| health | all 4 supervised processes RUNNING (`nest-api`, `nest-ui`, `nest-rank`, `nginx`) via `supervisorctl status` inside the container |
| path split | `/` 200, `/login` 405, `/register` 400, `/theme-init.js` 200 — all through Cloudron's own reverse proxy, matching the local prediction exactly |
| logs | clean over the observed window; zero matches for `\berror\b\|panic\|EACCES\|connection refused\|\bfailed\b` |
| secrets: mode/owner | all four secret files `600 cloudron:cloudron` |
| secrets: restart idempotency | sha256 byte-identical across a `cloudron restart`; explicit `==> existing X found, keeping it` log line present after the `1.0.0-2` fix |
| secrets: update idempotency | sha256 byte-identical across a real `cloudron update` (not just a restart) from `1.0.0-1` to `1.0.0-2` — a real early pass of gate 3's update-leg secret invariant, ahead of schedule |

**Defect found and fixed on the live throwaway, not just locally:** `1.0.0-1` shipped the duplicate
`daemon off;` nginx bug (full writeup above). The on-server build for `1.0.0-1` cost roughly the
better part of an hour on the rig; the fix was rebuilt locally in under a minute and delivered as a
`cloudron update` via a direct `docker save | ssh | docker load` transfer, avoiding both a second
on-server compile and any registry push. `cloudron update` took a real backup automatically as part
of the update — usable as a genuine pre-fix snapshot for gate 3's restore leg later, not a synthetic one.

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

## Gate 2, resolved: HTTPS never pushes, at all, regardless of authentication

Superseded, 2026-08-05: the question below was "how does HTTPS push authenticate", which assumed
HTTPS push exists. **It does not.** Observed directly (`404 Not Found` on a real push attempt against
the live throwaway install) and then confirmed by reading `dot_pijul.rs` end to end:
`api/src/repository/dot_pijul.rs`, the handler behind the `.pijul` HTTP route, implements only
`Changelist`, `Change`, `State`, `Identities` and `Id` — every one a read. There is no apply/write
branch anywhere in the file. The real write path, `self.apply(hash, file, size, chan, &mut session)`,
lives entirely in `api/src/ssh.rs`. Pushing requires SSH, unconditionally, for public and private
repositories alike. `README.md`, `DESCRIPTION.md`, `POSTINSTALL.md`, `CHANGELOG.md` and this file's own
earlier framing all claimed otherwise and have been corrected.

The bearer-token mechanism below is real and still accurate as a description of the code, but it
authenticates **reads of private repositories over HTTPS**, not push. Kept for that reason, retitled
so a future reader does not draw the same wrong inference this round did.

### The bearer-token mechanism (for private-repo reads, not push)

`api/src/repository/dot_pijul.rs` resolves the caller via
`crate::http_auth::bearer_user(&config, req.headers())` — an `Authorization: Bearer <token>` header,
checked with a single HMAC and no database lookup. **Not** the browser session cookie, and **not**
HTTP Basic auth. `bearer_user` returns `None` (anonymous) rather than an error when the header is
absent, which is why a plain, unauthenticated `pijul clone` of a **public** repository over HTTPS
works with no setup at all; a private repository's read presumably needs this token.

The token itself comes from a distinct flow, documented in `http_auth.rs`'s own module comment: the
client signs a canonical payload (the host, under SSHSIG namespace `pijul-http-login`) with a
registered SSH key and `POST`s the signature to `/login/ssh`, in exchange for a 24-hour bearer token.
So even for the read-only case, authentication is keyed off the **same SSH public key** a user would
otherwise use for SSH push, not off their password. **Still not exercised by any test in this
package** — see `docs/PACKAGING-NOTES.md` "Still open".

## Gate 3 risk, found ahead of time and NOT yet resolved: a live backup may race a live push

Found while checking whether `sanakirja` (every repository's storage engine) needs `persistentDirs`
plus a logical `backupCommand`/`restoreCommand`, the way gate 3's own doctrine requires for a store
with background file churn. **This is not settled and needs an empirical test in gate 3, not a
guess**, but the mechanism is real enough to write down now rather than risk losing it.

**The mechanism, read from `sanakirja`'s own source (`environment/mod.rs`, `environment/muttxn.rs`):**
a sanakirja file holds a small fixed number of "root pages" (2 by default in the crate's own
example). A commit works by taking an OS **advisory** exclusive lock (`lock_exclusive`, a plain
`flock`-family call on the `File`) on the *oldest* committed root page, then **overwriting that page
in place** with a copy of the newest root, and unlocking. Readers take a **shared** advisory lock the
same way. This is cooperative locking: it only serialises processes that call sanakirja's own lock
methods.

**Cloudron's backup is not one of those processes.** `cloudron-platform-facts.md` records that
Cloudron copies `/app/data` *while the application is running*, and there is no reason to expect a
filesystem-level copy (rsync-shaped or otherwise) to take a sanakirja-aware advisory lock on every
repository file it walks past — it has no way to know sanakirja's locking convention exists. So there
is a window, during the in-place root-page overwrite of an active commit, where an unsynchronised
backup reading that same file could observe the page mid-write.

**What is genuinely unknown, and must not be asserted either way without a test:**

- Whether a torn root page corrupts the whole pristine store, or whether sanakirja's two-root-page
  design degrades gracefully (the *other*, untouched root page still describing a valid, if slightly
  older, committed state) — these are very different severities and the source alone does not settle
  which one this is under an actual concurrent backup.
- Whether the write itself, at a single 4096-byte page, lands atomically enough in practice that the
  window is narrower than it looks on paper. Page-cache read/write interleaving between an mmap'd
  writer and a `read()`-based copier is a genuinely subtle kernel question, not something to resolve
  by reasoning from a crate's doc comment.

**The gate 3 test this needs, precisely:** push changes to a repository in a tight loop from a
background script while a `cloudron backup create` runs concurrently, several times, then restore
from one of those backups and verify every pushed change is present and `pijul log`/`pijul clone`
succeed without error on the restored repository. Run it enough times to make a narrow race window
plausible to hit, not just once.

**If the risk turns out real**, the fix is the one gate 3's own doctrine already names for this class
of application: move `repositories/` onto a `persistentDirs` path (excluded from the raw filesystem
walk) and back it up through `backupCommand`/`restoreCommand` with a logical export instead — which
for Pijul most plausibly means iterating repositories and using the `pijul` client's own bundle/export
path rather than a raw file copy, since that goes through the application's own consistency guarantees
rather than around them. That is a real architectural change and deserves an ADR of its own if gate 3
confirms it is needed; it is not something to build speculatively before the test says so.

## Gate 4 precondition, settled ahead of time: the primary store is memory-mapped

Gate 4's own doctrine requires establishing, before measuring anything, whether the application's
primary store is memory-mapped, because that decides which cgroup counter the pass/fail verdict is
read against, and getting it wrong produces a check that can never pass however well the app is sized.

**It is.** Every repository's data lives in a `sanakirja` pristine store (`pijul-core`'s dependency,
pinned `sanakirja = "2.0.0-beta"`), and `sanakirja` builds with `default = ["mmap"]` via `memmap2`.
Confirmed by reading its own source rather than inferring from the name: `src/debug.rs` and
`src/tests.rs` both dereference through `env.mmaps.lock()[0].ptr`.

**Consequence for gate 4:** `memory.peak` is not the counter to gate on. The page cache backing every
open repository's mapped pristine file will expand to fill whatever the cgroup allows and is charged
to the cgroup, so `memory.peak` will converge toward `memoryLimit` regardless of how well the limit is
sized. The verdict must instead be read against a **single sample** of `memory.stat anon` plus
`memory.swap.current`, taken together, per the gate 4 reference. Record `memory.peak` in the evidence
table for context, with a one-line note explaining why it sits near the cap, but do not gate on it.

One more thing worth planning for now: the number of **concurrently open** repositories under load is
the load-bearing variable for a memory-mapped store, not request count. The gate 4 load recipe should
touch several distinct repositories, not the same one repeatedly, or the loaded figure will
understate a real multi-repository instance.

## Gate ladder

Not yet run past gate 0's rendering step. Gates 1 to 4 execute against the shipping digest and their
evidence lands here.
