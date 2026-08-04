# Notes for the Cloudron team

Verified platform observations from packaging the Pijul Nest, anonymised. Offered as the kind of
thing that might make Cloudron better for this class of application, not as bug reports.

## 1. The base image satisfied a large Rust binary with nothing added

`cloudron/base:5.0.0` resolved every dynamic dependency of a 52 MB Rust binary with no additional
packages at all:

```
$ ldd nest        # against a bare cloudron/base:5.0.0
    libsodium.so.23, libssl.so.3, libcrypto.so.3, libgcc_s.so.1, libm.so.6, libc.so.6
```

`libpq5`, `psql` and `pg_dump` are also present, so `diesel-cli` runs at boot for migrations without
a runtime layer either. For a Rust plus PostgreSQL application, the runtime stage is a pure `COPY`.
That is worth advertising: the packaging documentation's Rust guidance is thin, and the practical
answer here is better than the docs imply.

## 2. A managed-database class of failure that is invisible to local testing

The Nest's migrations contain `GRANT ... TO <a hardcoded role>`. The `postgresql` addon's role is
`NOSUPERUSER NOCREATEROLE`, so it cannot create that role, and the first migration fails.

This is the same class as gotcha #148 in our own notes, and the general shape recurs: an upstream
whose own deployment runs migrations as a superuser bakes an assumption into its SQL that a managed
addon cannot satisfy. **The failure is invisible to any local test that uses a stock PostgreSQL
sidecar**, because such a sidecar's bootstrap user is a superuser.

What would help packagers: documenting the addon role's exact grants, so a local test can be built
that fails the same way the platform would. We reproduced it locally only by deliberately creating a
`NOSUPERUSER NOCREATEROLE` role, which is not an obvious thing to think of doing.

Confirming the good news too: **`citext`, `pg_trgm` and `pgcrypto` all create successfully as the
addon-style unprivileged role**, both as database owner and as a non-owner holding only `CREATE`,
because all three are trusted extensions. Extension-creating migrations are not automatically a
problem; role-creating ones are.

## 3. `tcpPorts` and applications that serve SSH themselves

The Nest implements SSH in process rather than through the system daemon, which is the Forgejo and
Gitea pattern, and it defaults to port 22. Cloudron handles this well through `tcpPorts` with a
`containerPort`, and the app needed only to be told to listen above 1024.

The wrinkle worth documenting is upstream's reason for running as root: it binds the privileged port
first and then drops privileges itself. Packagers meeting `User = root` in an upstream unit are
likely to conclude the application needs root, when the actual requirement is a privileged port that
`tcpPorts` makes unnecessary. A sentence in the `tcpPorts` documentation to that effect would save
that reasoning being redone.

## 4. Non-HTTP surfaces are invisible to the health check

`healthCheckPath` covers HTTP only. An application whose primary use is `pijul push` over SSH can be
fully healthy by that measure while its SSH listener is dead. There is no manifest field that says
"this TCP port should also accept connections".

Not a request for one necessarily, but worth noting that for git-hosting-shaped applications the
health check covers the less important half of the service.
