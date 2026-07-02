# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-07-02

Initial public release.

### Added
- Full T-SQL maintenance script for SUSDB (`sql/WSUS-SUSDB-Maintenance.sql`) covering:
  - Environment validation and automatic, safe compatibility-level detection (never forces a fixed level, never downgrades).
  - Targeted, fragmentation-driven index maintenance (REORGANIZE/REBUILD) based on the thresholds published in Microsoft's official WSUS reindex script.
  - Statistics refresh, defaulting to `sp_updatestats` with an opt-in `FULLSCAN` mode.
  - Batched synchronization-history cleanup (`tbEventInstance`) to control transaction log growth.
  - Superseded-update decline logic with a safe dry-run default and a two-flag confirmation gate before any live decline.
  - Optional full index rebuild pass (off by default, two-flag opt-in), as a documented replacement for `sp_MSforeachtable`.
  - Centralized configuration via `SESSION_CONTEXT` (SQL Server 2016+), with an explicit engine-version guard that fails fast and clearly on unsupported (pre-2016) engines.
  - Structured, queryable run logging (`#MaintenanceLog`) and persisted per-item error detail (`#ErrorDetail`) — not just `PRINT` output.
  - `TRY...CATCH` around every critical and per-item operation, so a single failure never aborts an entire maintenance pass.
- Full documentation set: `README.md`, `docs/ADMIN-GUIDE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`.
- MIT License.

### Design decisions
- No undocumented system procedures (`sp_MSforeachtable`, `sp_MSforeachdb`) are used anywhere in the script — replaced with documented catalog views (`sys.tables`, `sys.indexes`, `sys.schemas`) and dynamic SQL.
- Every destructive or expensive operation is opt-in and off by default; the two heaviest/riskiest operations (full rebuild, live decline of superseded updates) require an explicit **second** confirmation flag in addition to their "enable" flag.
- Compatibility level is only ever raised to match the detected engine version, never forced to a hardcoded value, never lowered.

[1.0.0]: https://github.com/brahim-o-tech/wsus-susdb-toolkit/releases/tag/v1.0.0
