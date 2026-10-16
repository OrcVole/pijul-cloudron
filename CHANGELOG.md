[1.3.0]

- Upstream pijul-nest 314 to 334 (twenty changes, 2026-09-23 to 2026-10-14). Pinned to change
  LCSUXC3X2NXI4YVUSFJFQORRLLGFQ4AA6JPS5DWXENMW4POGXASAC, state EKU6JV7NJTYKPKCJAZ2PGLKUOFFOQM3VAB7ZKTR4PUBTGBGNGXSAC
  (2026-10-14). Upstream has no release notes; this is written from the change messages.
- Sign-in by SSH key is tightened: the signature is now bound to a one-use challenge issued by the server
  that names the account, and API clients can use the resulting bearer token. Single-use challenges are
  tracked in memory, so a restart simply invalidates any challenge in flight.
- Discussions: maintainers are notified when a discussion is opened, review comment counts show per author
  on discussion patches, and the hunk-context view lists every hunk, ordered by full path, with additions,
  deletions and moves titled.
- CI: jobs can now run per system (`[systems]` in `pijul.toml`) on other runners, and a stopped job gets
  SIGTERM before SIGKILL. CI stays disabled in this package.
- Two database migrations, applied automatically on first start: `discussion_subscription_unique` (removes
  duplicate discussion subscriptions, keeping the earliest, then makes each pair unique) and `job_system`
  (adds a nullable column to `jobs`).
- Base image cloudron/base 5.1.0 to 6.0.0 (Ubuntu 26.04). Base 6 ships no Node.js, so the web interface
  now runs on Node.js 24.19.0 copied from the official node:24.19.0 image to the same path the old base
  used (the version is unchanged).

[1.2.1]

- Upstream pijul-nest 303 to 314 (ten changes, 2026-09-04 to 2026-09-23).
- Safer pushes: a failed push no longer leaves partial state behind, and writes to a repository are
  now serialised inside the Nest.
- CI jobs are stopped immediately and visibly when killed, and each job's vulnerability scan is now
  summarised by severity in the job list. This adds one database migration (`job_scan_severity`),
  applied automatically on first start.
- Review fixes: approving a patch twice is harmless, landed patches are marked, and change pages
  handle deleted directories.
- Base image cloudron/base 5.0.0 to 5.1.0: the Ubuntu 24.04.4 point release, with its OS security
  updates. The web interface now runs on Node.js 24.19.0 (was 22.14.0), which is what 5.1.0 ships.

[1.2.0]

- Upstream pijul-nest 224 to 303
- Routine code updates across API and UI with no schema, migration or auth changes
- No upgrade steps or new settings required
- Labelled a minor rather than a patch on purpose: upstream is not versioned with release notes,
  so the span was assessed from the file-level diff of 79 changes rather than from what each one says

[1.1.0]

- Update pijul-nest 174 -> 224
- Routine features and fixes from upstream
- Pins NEST_STATE, NEST_CHANGE and NEST_DATE moved to ordinal 224
- No packaging changes: auth topology, workspace layout and secrets handling unchanged; base and built images digest-pinned

[1.0.0]

- First release.
- Upstream change: SX4EP5B4JDSLV4SDIB2A43MJANAR66IHKRCK3KPNVLJIG4OCYY6QC (2026-08-04)
- Pijul Nest, the repository hosting platform for the Pijul version control system.
- Cloning over HTTPS out of the box; pushing needs SSH, on a port chosen at install time.
- Billing, CI and Zulip notifications are disabled.
- Private repository and storage quotas raised from the hosted service's defaults.
