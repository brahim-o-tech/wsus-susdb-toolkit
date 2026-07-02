# v1.0.0 — Initial public release

**WSUS SUSDB Maintenance Toolkit** — a hardened, production-ready T-SQL
script to recover a bloated or unresponsive WSUS database and restore
reliable SCCM/MECM ↔ WSUS synchronization, without relying on undocumented
SQL Server internals.

## Highlights

- 🚫 **Zero undocumented system procedures** — `sp_MSforeachtable` and
  `sp_MSforeachdb` are never used; replaced with documented catalog views
  and dynamic SQL.
- 🛡️ **Safe by default** — every destructive or expensive operation is
  opt-in. The two heaviest operations (full index rebuild, live decline of
  superseded updates) require a **second, explicit confirmation flag** on
  top of their enable flag.
- 🔍 **Automatic, safe compatibility-level detection** — raises SUSDB's
  compatibility level to match the detected engine, never forces a
  hardcoded value, never downgrades.
- 📊 **Structured, queryable logging** — `#MaintenanceLog` for per-step
  summaries and `#ErrorDetail` for individual failures, not just console
  `PRINT` output.
- 🧯 **`TRY...CATCH` everywhere it matters** — a single failed index or
  update decline no longer aborts the entire maintenance pass.
- 🖥️ **Works on WID and full SQL Server alike** — verified against
  Microsoft Learn documentation for SQL Server 2016 through 2025.

## What's included

- `sql/WSUS-SUSDB-Maintenance.sql` — the script
- `README.md` — full usage documentation
- `docs/ADMIN-GUIDE.md` — operational guide (when to run, what to enable, risks)
- `examples/` — three ready-to-use configuration profiles
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`

## Requirements

- SQL Server 2016 (13.x) or later, or Windows Internal Database on an
  equivalent-or-newer engine
- `db_owner` on SUSDB
- A full SUSDB backup before running

See [README.md](../README.md) for the complete requirements and warnings.

## Upgrade notes

This is the first release — no upgrade steps apply.

## Full changelog

See [CHANGELOG.md](../CHANGELOG.md#100--2026-07-02).

---

**Checksum (SHA-256) of `sql/WSUS-SUSDB-Maintenance.sql`:**
`<generate at release time — e.g. sha256sum sql/WSUS-SUSDB-Maintenance.sql>`
