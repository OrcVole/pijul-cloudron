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
