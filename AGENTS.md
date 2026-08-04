# Working contract

Settled decisions for this package. If you are about to re-derive one of these, read it instead.
If you believe one is wrong, say which line and why, and check it. Do not start over.

## The shape of the container

**Cloudron's `httpPort` points at nginx on 8000, never at either application process.** Upstream
splits one hostname across both by path, and the split is observable rather than theoretical: the UI
answers **404** for `/login` while the API answers **405** to a GET on it. Point `httpPort` at the UI
and you get a perfect front page where nobody can sign in.

The API paths are `/api`, `/login`, `/register` and `~ ^/[^/]+/[^/]+/\.pijul`. Everything else is the
UI's.

**Do not add nginx aliases for `/_app/`, `/fonts/` or `/theme-init.js`.** Upstream's vhost has them;
adapter-node serves all of them itself, verified returning 200 with correct content types. Upstream's
aliases buy `gzip_static`, `brotli_static` and immutable caching, which is an optimisation.

## Privileges

**`user` and `group` must stay absent from `config.toml`.** `api/src/config.rs` `drop_privileges()`
is a no-op when both are missing, which is exactly what lets the API run as `cloudron`. Setting them
makes the API attempt a setuid as an unprivileged user and panic, because `.apply()` is followed by
`.unwrap()`.

Upstream runs as root to bind SSH on port 22. We listen on 2222 and let `tcpPorts` map it, so root is
not needed. This is settled; do not reintroduce root.

## The database

**The migration rewrite is load bearing.** Upstream's migrations contain 59 `GRANT ... TO pijul`
statements. Cloudron's addon role is `NOSUPERUSER NOCREATEROLE` and cannot create that role, so
without the build-time rewrite to `CURRENT_USER` the first migration dies with `role "pijul" does not
exist`. The Dockerfile asserts the rewrite removed all of them; keep that assertion.

**Never add `--locked-schema`, and never restore `[print_schema]` to `diesel.toml`.** They make the
run apply everything and then fail on a formatting difference in a regenerated file, and at runtime
they would try to write into readonly `/app/code`.

Migrations run on every boot and are idempotent. That is verified, not assumed.

## Secrets

**Generate once, never regenerate.** The PBKDF2 password and salt must be byte-identical between the
API and the UI, and regenerating them locks every existing user out. Regenerating the SSH host key
gives every client a host-key-changed warning, which for a version control system reads as an attack.

`start.sh` re-asserts ownership and modes on **every** boot, not only the first. The API does not warn
when it cannot read its key material; it panics at `config.rs:140` and crash-loops.

The SMTP password file must exist even with mail unconfigured, because upstream's API wrapper reads it
unconditionally.

## Versioning

The package version is ours and describes the packaging. Upstream is unversioned and unreleased.
Every release records the upstream **state** hash and change hash in `CHANGELOG.md`. See
`docs/decisions/0001-versioning.md`.

**Pin by `--state`, not `--change`.** `pijul clone --change` panics against this repository, in
upstream's client. This is not a usage error and is documented in `docs/FOR-UPSTREAM.md`.

## Upstream contributions

**None, from any tooling.** Pijul's `CONTRIBUTING.md` says they may reject patches created
automatically by linters or LLMs. That is respected absolutely here: no issues, no patches, no
documentation fixes. `docs/FOR-UPSTREAM.md` exists so a human can raise things personally if they
choose to.

## Single sign-on

Out of scope, deliberately. There is no OIDC or LDAP upstream to map onto. `proxyAuth` is the wrong
answer for a version control system: it gates the whole HTTP surface, which means breaking push.
