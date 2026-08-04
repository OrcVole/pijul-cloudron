# Packaging notes

The verified-versus-assumed log, newest first. Anonymised: no real domains, no host inventory.

A claim gains no confidence on its way up this document. If something was inferred it says inferred,
and if a check has never been watched failing it is a claim rather than evidence.

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
- **HTTP clone and push works through the `.pijul` path rule.** The route is proxied and the API
  answers on it, but no actual `pijul clone` over HTTPS has been run against this package yet.
- **`pbkdf2Iterations` of 600000.** Upstream's default is `1`, which is not defensible to ship. The
  value chosen is conventional for PBKDF2-HMAC-SHA512 rather than measured against this application's
  login latency.

### NOT DONE, and carried forward rather than ticked

- **No browser has rendered the page.** Three headless routes hung with no output. The HTML parses
  and every asset returns 200, but HTML that parses is not a page that renders, which is the whole
  point of the rule this is failing. Gate 0 builds a working browser harness first.
