# Notes for the Pijul team

Written while packaging the Nest for Cloudron, offered gratefully. Everything here was found by
reading your own source and running it, and nothing here is a complaint: the Nest packaged more
cleanly than most applications of its size, and `nest.nix` is the best deployment documentation this
packaging workflow has encountered.

**Nothing in this file has been or will be sent to you by automated tooling.** Your `CONTRIBUTING.md`
says you may reject patches created automatically by linters or LLMs, and that is respected here
absolutely: no issues, no patches, not even documentation fixes. This file exists so that a human who
wants to raise any of it has the evidence to hand.

## 1. The migrations hardcode a role name that a managed database cannot create

`migrations/` contains **59 `GRANT ... TO pijul` statements across 24 files**, and your NixOS module
compensates by running `createuser pijul` in `preStart`.

On any managed PostgreSQL, the application's role is typically `NOSUPERUSER NOCREATEROLE` and cannot
create another role, so the very first migration fails:

```
Failed to run 2024-11-23-114911_diesel with: role "pijul" does not exist
```

Granting to `CURRENT_USER` instead would be equivalent in your own deployment, since the migrating
role already owns every table it has just created, and would work unchanged on a managed database.
The grants become no-ops rather than failures.

This is the single change that would most reduce the work of packaging the Nest for anything that
does not hand out superuser.

## 2. `identicon/pkg` and `identicon/pkg-node` are undocumented build prerequisites

`pnpm-workspace.yaml` lists both as workspace members and `pnpm-lock.yaml` carries importers for
both, but neither directory exists in the repository: they are `wasm-pack` output. `pnpm install
--frozen-lockfile` cannot be satisfied until they exist, and `wasm-pack` appears only in
`default.nix`'s development shell, so anyone building outside Nix has to work this out.

Two lines in the README covering `wasm-pack build identicon --target web --out-dir pkg` and the
`--target nodejs --out-dir pkg-node` variant would save that.

## 3. `pijul clone --change <hash>` panics on the Nest repository

Reproducible with the current client, `pijul 1.0.0-beta.21`, against
`https://nest.pijul.com/pijul/nest`:

```
$ pijul clone --change SX4EP5B4JDSLV4SDIB2A43MJANAR66IHKRCK3KPNVLJIG4OCYY6QC https://nest.pijul.com/pijul/nest
Repository created at ...
pijul had a problem and crashed.
```

The crash report says:

```
Panic occurred in .../pijul-core-1.0.0-beta.20/src/change.rs at line 1663
cause = called `Result::unwrap()` on an `Err` value: IoHash {
    err: Os { code: 2, kind: NotFound, message: "No such file or directory" },
    hash: 2QMA3JQXSSDMQPXI2G73GAP3JINFXRG74XPSQXJMJ6FYPHVDYQ4QC }
```

The stack runs through `apply_change_rec_ws` and `changestore::filesystem::get_change`, so it looks
as though a dependency is applied before its change file has been downloaded. Two observations that
may narrow it: `pijul clone --state <hash>` against the same repository works and yields exactly the
tree `--change` was asked for, and a plain `pijul clone` works.

This matters to anyone packaging the Nest, because pinning a build to an exact upstream point is the
first thing a packager must do, and `--change` is the natural way to reach for it.

## 4. `pnpm-workspace.yaml` lists a `pijul-diff` package that does not exist

Harmless, since nothing depends on it, but it sends a reader looking for a directory that is not
there.

## 5. The checked-in `api/config.toml` disagrees with `nest.nix` on nearly everything

The repository-root config carries `etcd_server = "localhost:2379"` and ports 8000/8001/8080/2222,
while the module that generates the production config emits no etcd line at all and uses 5000/5001/22.

Reading the checked-in file as the deployment contract, which is the natural thing for a packager to
do, produces an invented dependency on etcd and a completely wrong port map. It nearly cost this
round its viability verdict.

A one-line comment at the top of `api/config.toml` saying it is a development configuration and
pointing at `nest.nix` would prevent that entirely.

## 6. Small things

- **`pbkdf2Iterations` defaults to `1`** in `nest.nix`. Given the option's own description says it
  must match between the API and the UI, a reader may take the default as a considered value rather
  than a placeholder.
- **`api-start` reads `smtpPasswordFile` unconditionally**, outside any `optionalString`, so the file
  must exist even when `email = null`. A deployment with no mail configured still has to invent one.
- **`limits.freePrivateRepos` defaults to `0`.** Correct for your hosted service, but a self-hosted
  instance that takes the defaults gives its users no private repositories at all, which reads as a
  bug rather than a policy.
- **Discovering `?raw` on a tree URL took several attempts.** `https://nest.pijul.com/pijul/nest/tree/nest.nix?raw`
  is the only way to read a single file without a client, and it does not appear to be documented.

## 7. Thank you

`nest.nix` states what is mandatory, what is optional, what the real defaults are, how many services
there are and which user each runs as. Most projects leave a packager to infer all of that from a
README. Publishing it is a genuine kindness to anyone deploying the Nest outside NixOS, and it is
worth knowing that it is being read that way.
