# ADR 0001: the package owns its version, and pins upstream by change hash

**Status:** accepted
**Date:** 2026-08-04

## Context

Cloudron requires a semver `version` in `CloudronManifest.json`, and `CloudronVersions.json` requires
that version to increase monotonically across releases. Every package this workflow has produced so
far has taken that number from upstream, so the question never came up.

The Nest cannot supply one. It is **not versioned and not released**: no tags, no release notes, no
version in `api/Cargo.toml` beyond a placeholder `0.1.0` that has never moved. The only identifier a
build can be pinned to is a **change hash**, which is a 53-character base32 string with no ordering
relation to any other change hash.

Three further facts shape the decision:

- The tree moves quickly. On the day of the first clone, **three changes landed**, the most recent
  about two hours before the clone.
- A build **can** be pinned exactly and reproducibly, though not the obvious way. `pijul clone
  --change <hash>` exists and **crashes** against this repository: it fetches the change and its
  dependencies and then panics in `pijul-core 1.0.0-beta.20` at `change.rs:1663`, deserialising a
  dependency whose file is not on disk. `pijul clone --state <hash>` produces exactly the intended
  tree and exits 0. So the pin is a **state** hash, with the change hash recorded alongside it and
  asserted after the clone.
- Two other version numbers exist nearby and belong to different things. The Pijul **client** is
  `0.15.0` on crates.io while the website recommends `~1.0.0-beta`, and neither describes the Nest.

## Decision

**The package version is ours, and it describes the package, not the application.**

- `CloudronManifest.json` carries a plain semver owned by this repository, starting at `1.0.0`.
- The upstream change hash is pinned in the Dockerfile as a build argument and recorded in
  `CHANGELOG.md` for every release, so any shipped image can be traced to an exact tree.
- **Minor** bump when the pinned upstream change moves. **Patch** bump for packaging-only changes.
  **Major** bump only for a change that breaks an existing install, which per gotcha #174 is a fresh
  round rather than an update.

## Why not the alternatives

**Date-based, such as `0.20260804.0`.** Monotonic and valid semver, and it does encode when the tree
was taken. Rejected because it reads as an upstream version to anyone scanning the app store, and it
throws away the distinction between "upstream moved" and "we fixed our own packaging", which is the
distinction an operator deciding whether to update actually wants.

**Deriving something from the change hash.** There is nothing to derive. Change hashes have no order,
so no function of one produces a monotonic sequence.

**Adopting the client's version.** `0.15.0` or `1.0.0-beta` would be a plain untruth: those number
a different program, and a user seeing `1.0.0-beta` would reasonably expect the beta client's
behaviour and support window.

## Consequences

- The package version says nothing about upstream, so **`CHANGELOG.md` has to carry the change hash
  on every entry**. Without it the version is untraceable, which is worse than the problem being
  solved. This is the load-bearing obligation of this decision.
- Automated update tooling cannot watch a tag or a release feed. Watching for a new change on the
  `main` channel is possible but noisy, given the observed rate of several changes a day, so updates
  are a deliberate decision rather than a scheduled one.
- The first release being `1.0.0` claims stability of **the packaging**, not of the Nest. The
  `POSTINSTALL` and store description say so plainly, because the Nest is pre-release software that
  its own authors have not versioned.
