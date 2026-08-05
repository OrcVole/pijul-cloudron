# Packaging notes

The verified-versus-assumed log, newest first. Anonymised: no real domains, no host inventory.

A claim gains no confidence on its way up this document. If something was inferred it says inferred,
and if a check has never been watched failing it is a claim rather than evidence.

---

## 2026-08-05, gate 2 against the real throwaway install: registration through repo creation, and a corrected claim

### CORRECTED: HTTPS does not push

**Every earlier document in this package, including this one, said push worked over HTTPS. It does
not.** Confirmed from source, not inferred: `api/src/repository/dot_pijul.rs`, the handler behind the
`.pijul` HTTP route, implements only `Changelist`, `Change`, `State`, `Identities` and `Id` — all
reads. There is no apply/write path anywhere in that file. The actual write path,
`self.apply(hash, file, size, chan, &mut session)`, lives entirely in `api/src/ssh.rs`. **The Nest's
HTTPS surface is read only: browsing and cloning. Pushing requires SSH, unconditionally**, regardless
of whether a repository is public or private.

This was found by running `test/gate2-flows.sh`'s push leg for real and getting `404 Not Found` on
both the push and the follow-up clone, then reading `dot_pijul.rs` end to end rather than assuming a
write path existed somewhere further down the file. `README.md`, `DESCRIPTION.md`, `POSTINSTALL.md`,
`CHANGELOG.md` and `nginx.conf`'s comments all previously claimed HTTPS push and have been corrected.
The install-time framing of the SSH `tcpPorts` entry as an optional convenience is also now known to
be wrong in consequence: leaving it disabled does not trade away agent-based auth, it removes the
ability to push to the instance at all.

### VERIFIED, against the live throwaway install (not local, not predicted)

- **Registration → email confirmation → sign-in → repository creation all pass end to end**, using
  real HTTP requests against `pijul-testing.haggis.top`, not curl against a local stand-up.
- **The confirmation token needs padded base64url**, matching `data_encoding::BASE64URL` exactly.
  Stripping the `=` padding (an earlier version of `test/gate2-flows.sh` did this) fails silently:
  `register_get`'s own fallback path swallows the decode error and redirects to `/` with no cookie
  set, indistinguishable from a real failure by status code alone. Only the `Location` header
  distinguishes the two paths (`/<login>` on success, `/` on any failure).
- **Repository creation is `POST /api/settings/repo/add`, not `/repo/add`.** `settings.rs`'s own route
  table reads `.route("/repo/add", post(create_repo))`, and it is easy to stop there without tracing
  the full `.nest("/api", ...)` → `.nest("/settings", ...)` chain that composes the real path. Posting
  to the bare path hits nginx's UI catch-all instead of the API, and **SvelteKit's own built-in origin
  check rejects it with "Cross-site POST form submissions are forbidden"** — an unrelated mechanism
  whose error text reads exactly like a CSRF rejection and pointed the investigation the wrong way
  until the response body was read instead of trusting the status code alone.
- **The CSRF value to submit is not the raw `Csrf_Token` cookie.** Read from `axum_csrf` 0.11.0's own
  source: the cookie holds a random `self.token`; the value a client must submit is
  `authenticity_token()` — `HMAC-SHA256(salt, self.token)`, base64-encoded, computable only
  server-side. It arrives as the plain `"token"` field in the JSON body of any authenticated GET that
  extracts `CsrfToken`, concretely `GET /api/settings`'s response. Submitting the raw cookie value
  decodes fine but verifies against the wrong thing, producing the same misleading origin-check error
  text once the path above is also fixed — only reading `token.rs`'s `verify()` implementation
  settled which of the two failures was actually firing.
- **`cloudron exec` degraded mid-session**, matching field-guide gotcha #167 exactly (repeated
  `ETIMEDOUT` on trivial calls). Switched to `ssh <rig> docker exec` by the app's `fqdn` label, which
  stayed reliable for the rest of the session.
- **A bash gotcha, unrelated to the app:** an apostrophe inside a `${VAR:?message}` parameter
  expansion breaks bash's parser, even though the whole expression sits inside outer double quotes —
  bash scans for quote balance inside the braces independently of the outer quoting context. Cost a
  real debugging cycle before being traced to that one character.

### Still open

- The SSH push path itself is not yet exercised by any test in this package. `test/gate2-flows.sh`'s
  push/pull leg currently only proves HTTPS clone works and correctly does not attempt to push over
  HTTPS. An SSH-based push test is the next real gap, not yet closed.

---

## 2026-08-05, phases 2 to 6: scaffold, local validation, first throwaway install

### VERIFIED

**`pijul clone --change <hash>` panics against this repository; `--state <hash>` does not.** The
crash is in `pijul-core 1.0.0-beta.20` at `change.rs:1663`, an `IoHash` deserialisation `unwrap()` on
a dependency file that is not on disk. `--state` produces the identical tree and exits 0. The pin is
therefore a state hash, with the change hash asserted after clone as a cross-check
(`pijul log --limit 1 --hash-only`). Written up for upstream in `docs/FOR-UPSTREAM.md` and never sent.

**The nginx front proxy needs no aliases for `/_app/`, fonts, or `theme-init.js`.** adapter-node
serves all of them itself; upstream's aliases are a `gzip_static`/immutable-caching optimisation, not
a requirement. Verified by request, not inferred from the vhost.

**A build that "succeeded" had shipped a dead front proxy.** `1.0.0-1`'s `supervisor/nest.conf`
started nginx with `-g "daemon off;"` while `nginx.conf` itself also set `daemon off;`; nginx rejects
the directive given both ways and supervisor gave up after four restarts in seven seconds. Every other
process reported healthy. Invisible to container-`Up` status; only an actual request against the port
showed it. `test/local-stack.sh` caught it immediately (all five path-split checks returned `000`).
Fixed in `1.0.0-2`: 13/13 local checks pass.

**The browser render check needed manual DevTools-protocol driving, not the obvious CLI flags.**
`--dump-dom`/`--screenshot` hung with no error against the live app across three different headless
routes. The page opens a persistent SSE connection, which appears to prevent Chrome's implicit
wait-for-`load` from ever resolving in headless mode, even though the DOM is long since rendered.
Fixed by launching Chrome once with `--remote-debugging-port`, driving `Page.navigate` over the
DevTools WebSocket, and using a **fixed** wait instead of the load-event heuristic
(`test/support/cdp-screenshot.py`). The resulting screenshot shows a fully rendered login page: fonts
loading, the brand wordmark, live data from the database.

**`secret-scan.sh`'s clean pass with `.anonymize-list` absent was not evidence of anything.** Only
generic shapes were checked. Populating the real denylist immediately surfaced a false positive (the
manifest's own declared `contactEmail`, which `START-HERE.md` explicitly permits) and the fix was
verified in both directions: exit 0 with only the allowed field present, exit 1 the moment a planted
`haggis.top` string appeared anywhere else. The scanner's detection itself was also negative-tested
with a planted fake `ghp_` token (exit 1) and its removal (exit 0), per the round's own rule that a
passing check is a claim until its failure has been observed.

**Registration and repository creation, read from source ahead of gate 2:**

- `POST /register` creates the user with `email_is_invalid = true`, inserts a token, sends a
  confirmation email, and **deletes the row if the send fails** — a broken `sendmail` wiring looks
  like every registration failing with a generic `alreadyExists` error, no other diagnostic.
- `GET /register?token=<base64url>` is the confirmation link, same route as signup, split by method.
  This is why a bare `GET /register` returns 400: `token` is a required query field and Axum's `Query`
  extractor rejects the request before the handler runs. (Observed and asserted correctly in gate 0
  testing before this explanation existed.)
- The confirmation token can be read directly from the `tokens` table (raw bytes; only the emailed
  link is base64url-encoded), so gate 2 needs no live inbox to exercise this path.
- `POST /repo/add` creates a repository: session-gated, CSRF-protected via `axum_csrf`'s
  double-submit pattern (cookie plus a form-field token, not the cookie alone), idempotent via
  `on_conflict_do_nothing`.

**`sanakirja`, the crate behind every repository's pristine store, is memory-mapped.** Confirmed from
the vendored crate source (`default = ["mmap"]` via `memmap2`; `env.mmaps` dereferenced directly in
its own `debug.rs`/`tests.rs`), not inferred from the name. This means gate 4 must read its verdict
against a single sample of `memory.stat anon` plus `memory.swap.current`, never `memory.peak`, which
will otherwise converge toward `memoryLimit` regardless of sizing and fail every correctly configured
install. Settled before any measurement was taken, per the gate's own precondition.

**The manifest's default `NEST_SSH_PORT` (29418) collided with a sibling app on the first real
install attempt.** A genuine platform-level conflict (`409 Conflicting tcp port 29418`), not a
packaging defect; resolved by picking a free port (29500) for the throwaway install via `-p`. Worth
a note in `POSTINSTALL.md` that the suggested default may need changing at install time on a box with
many existing `tcpPorts` apps.

### INFERRED, not yet verified

- Everything under "NOT DONE" from the 2026-08-04 entry that is not repeated above.
- The gate 2 repo-creation CSRF token selector (`test/gate2-flows.sh`) is a prediction against the
  rendered dashboard HTML, not yet observed on a live instance.
- `nest-rank`'s six-hourly loop has not yet been observed completing a real run.

---

## 2026-08-04, phase 1: proving the two open questions

### VERIFIED

**The whole workspace builds with plain cargo, no Nix.** `cargo build --release --locked` over all
six workspace members: 65 seconds, exit 0, from a cold registry, in a container based on
`cloudron/base:5.0.0` with an ordinary apt library list. Upstream's `flake.nix` overrides are all
ordinary system libraries, so Nix is their convenience rather than a constraint.

**The runtime stage needs no apt packages.** `ldd` of the `nest` binary against a **bare**
`cloudron/base:5.0.0` resolves `libsodium.so.23`, `libssl.so.3`, `libcrypto.so.3`, `libgcc_s`,
`libm` and `libc`, all from the base. `nest-rank` needs only libc, libm and libgcc.

**`libpq` is not a runtime dependency**, despite being in the build library list. It is absent from
the binary's linkage: the API talks to PostgreSQL through `diesel-async` over `tokio-postgres`, which
is pure Rust. `libpq` is needed only for `diesel-cli`, and the base already ships `libpq5`.

**The API runs unprivileged.** Started as uid 1000 with `user` and `group` omitted from
`config.toml` and SSH moved to 2222:

```
LISTEN 0 128 *:2222  users:(("nest",pid=1,fd=9))
LISTEN 0 128 *:5000  users:(("nest",pid=1,fd=10))
```

Both listeners held by pid 1 as uid 1000, and **no "Dropping privileges" line in the log**, which is
the observable proof that `drop_privileges` took its no-op branch rather than succeeding by accident.
SSH answered `thrussh_0.41.0` offering `password,publickey,keyboard-interactive`.

**Upstream runs as root only to bind port 22.** `api/src/main.rs` binds both listeners and *then*
calls `config::drop_privileges` at line 216, which is a no-op when `user` and `group` are absent.
Setting them on Cloudron would make the API attempt a setuid as the `cloudron` user and panic, since
`.apply()` is followed by `.unwrap()`.

**etcd is not involved.** The API serves with nothing listening on 2379 anywhere reachable, and its
logs never mention etcd. The `etcd_server` line in the checked-in `api/config.toml` is a developer
default; the module that generates the production config emits no such line.

**The migrations need `citext`, `pg_trgm` and `pgcrypto`, and all three create as an unprivileged
role.** Tested deliberately as `NOSUPERUSER NOCREATEROLE`, both as the database owner and as a
non-owner holding only `CREATE` on the database. Both succeeded: all three are trusted extensions.

**The migrations hardcode a role the addon cannot create.** 59 `GRANT ... TO pijul` statements across
24 of 28 migration files. Without a rewrite the first migration dies with `role "pijul" does not
exist`. Rewritten to `CURRENT_USER` at build time, all 28 migrations apply as the unprivileged role:
28 rows in `__diesel_schema_migrations`, 30 tables, 3 extensions. **A second run is a no-op and exits
0**, which is what makes running them on every boot safe.

**`--locked-schema` must not be used at runtime**, and `[print_schema]` must be stripped from
`diesel.toml`. With them, the run applies everything and *then* fails on a cosmetic formatting
difference in the regenerated `api/src/db.rs` between our diesel-cli and upstream's. At runtime it
would also try to write into readonly `/app/code`.

**One `httpPort` cannot serve this application, and the split is observable.** Through the proxy:
`/` 200 from the UI, `/login` **405** and `/register` **400** from the API. Straight at the UI,
`/login` is **404**. Pointing `httpPort` at the UI would render a perfect front page with signing in
impossible.

**adapter-node serves the static paths itself.** `/_app/immutable/...` returns 200 `text/css`,
`/theme-init.js` returns 200, and all eight web fonts return 200 `font/woff2`, all from the node
server. Upstream's nginx aliases for those paths are a `gzip_static` and immutable-caching
optimisation, not a requirement.

**Placing fonts in `ui/static/fonts/` is sufficient.** The SvelteKit build copies them to
`build/client/fonts/` where adapter-node serves them, so the package needs no nginx alias for fonts.

**The API panics rather than degrades on any missing secret.** With the host key unreadable it
panicked at `api/src/config.rs:140` with `CouldNotReadKey`. Each of `ssh_secret`, `PBKDF2_PASSWORD`,
`PBKDF2_SALT` and `PBKDF2_ITERATIONS` is an `.expect` or `.unwrap`, so any first-run mistake is a
crash loop rather than a degraded start.

**Upstream's own secret recipe**, from `secrets/generate.nix`:
`dd if=/dev/urandom bs=32 count=1 | base64 -w0`, for both the PBKDF2 password and the salt.

### INFERRED, not yet verified

- **`memoryLimit` of 2 GiB is a starting guess**, not a measurement. Gate 4 sets the real number.
- **The `sendmail` addon's variables map cleanly onto the UI's `SMTP_*` names.** Read from upstream's
  `ui-start` wrapper, never exercised: no mail has been sent.
- **`pbkdf2Iterations` of 600000.** Upstream's default is `1`, which is not defensible to ship. The
  value chosen is conventional for PBKDF2-HMAC-SHA512 rather than measured against this application's
  login latency.

### NOT DONE, and carried forward rather than ticked

- **No browser has rendered the page.** Three headless routes hung with no output. The HTML parses
  and every asset returns 200, but HTML that parses is not a page that renders, which is the whole
  point of the rule this is failing. Gate 0 builds a working browser harness first.
