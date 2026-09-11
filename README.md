# WSUS SUSDB Maintenance Toolkit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![SQL Server](https://img.shields.io/badge/SQL%20Server-2016%20--%202025-CC2927?logo=microsoftsqlserver&logoColor=white)](#supported-versions)
[![WID](https://img.shields.io/badge/Windows%20Internal%20Database-supported-blue)](#supported-versions)
[![Status](https://img.shields.io/badge/status-production--ready-brightgreen)](#)

A hardened, production-ready T-SQL maintenance script for **SUSDB**, the
database behind **WSUS** and **Configuration Manager / MECM Software Update
Points**. Built to recover a bloated or unresponsive SUSDB and restore
reliable SCCM ↔ WSUS synchronization — without relying on undocumented SQL
Server procedures.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Features](#features)
- [Screenshots](#screenshots)
- [Prerequisites](#prerequisites)
- [Supported versions](#supported-versions)
- [⚠️ Warnings — read before running](#️-warnings--read-before-running)
- [Quick start](#quick-start)
- [Configuration reference (SESSION_CONTEXT flags)](#configuration-reference-session_context-flags)
- [What each section does](#what-each-section-does)
- [Usage examples](#usage-examples)
- [Reading the results](#reading-the-results)
- [Best practices](#best-practices)
- [Known limitations](#known-limitations)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Microsoft Learn references](#microsoft-learn-references)
- [Contributing](#contributing)
- [Credits](#credits)

---

## Why this exists

WSUS/SUSDB maintenance guidance from Microsoft is scattered across several
Microsoft Learn articles and often leans on **undocumented, unsupported
system procedures** (`sp_MSforeachtable`, `sp_MSforeachdb`) copy-pasted from
forum posts. This project consolidates that guidance into a single,
documented, idempotent, and safe-by-default script that:

- Never uses undocumented SQL Server internals.
- Never runs a destructive or long-running operation without an explicit
  opt-in (and for the two heaviest operations, a **second** explicit
  confirmation flag).
- Logs everything it does to queryable temporary tables, not just console
  output.
- Works identically whether SUSDB sits on full SQL Server or on **Windows
  Internal Database (WID)**.

If you landed here because SCCM stopped syncing with WSUS and the console
times out on the Synchronizations node — this is for you.

## Features

- ✅ Automatic, **safe** compatibility-level detection (raises only, never forces, never downgrades)
- ✅ Fragmentation-driven index maintenance (REORGANIZE vs REBUILD, per Microsoft's published SUSDB thresholds)
- ✅ Statistics refresh — fast default (`sp_updatestats`) or optional full `FULLSCAN` pass
- ✅ Batched synchronization-history cleanup (controls transaction log growth)
- ✅ Superseded-update decline with a **safe dry-run default**
- ✅ Optional full index rebuild — off by default, double opt-in required
- ✅ Centralized configuration via `SESSION_CONTEXT` — no more hunting through the script to change a value
- ✅ Structured, queryable run log (`#MaintenanceLog`) and per-item error detail (`#ErrorDetail`)
- ✅ Zero undocumented system procedures
- ✅ Every critical and per-item operation wrapped in `TRY...CATCH` — one failure doesn't abort the whole run
- ✅ Compatible with SQL Server 2016 through 2025, and Windows Internal Database

## Screenshots

> _Replace the placeholders below with actual screenshots before publishing._

| Configuration (Section 0) | Run summary (Section 7) |
|---|---|
| `images/section0-configuration.png` | `images/section7-summary.png` |

| Console output during a reindex pass | Error detail table |
|---|---|
| `images/reindex-console-output.png` | `images/error-detail-table.png` |

## Prerequisites

- A SQL Server login with **`db_owner`** on SUSDB (or the combination of
  `db_ddladmin` + membership allowing `ALTER DATABASE` + `sp_updatestats` —
  `db_owner` is simplest and recommended for a maintenance window).
- SQL Server Management Studio (or SSMS Express) if SUSDB runs on **WID**
  (connect via `\\.\pipe\MICROSOFT##WID\tsql\query`), or `sqlcmd`/Azure Data
  Studio for full SQL Server instances.
- A **full backup of SUSDB** taken immediately before running the script.
- A genuine maintenance window for Sections 2 and 6 (index rebuilds are
  **offline** on Standard/Express/WID editions and will block concurrent
  WSUS/SCCM access to the affected tables).

## Supported versions

| Engine | Supported | Notes |
|---|---|---|
| SQL Server 2016 (13.x) | ✅ | Minimum supported version — `SESSION_CONTEXT` requires 2016+ |
| SQL Server 2017 (14.x) | ✅ | |
| SQL Server 2019 (15.x) | ✅ | |
| SQL Server 2022 (16.x) | ✅ | |
| SQL Server 2025 (17.x) | ✅ | Verified against Microsoft Learn compatibility-level documentation |
| Windows Internal Database (WID) | ✅ | Supported as long as the underlying engine is 2016+ (check the WID version shipped with your Windows Server release) |
| SQL Server 2014 (12.x) and earlier | ❌ | `SESSION_CONTEXT` is unavailable — the script fails fast with a clear error at Section 0 rather than proceeding |

## ⚠️ Warnings — read before running

- **Take a full backup of SUSDB before running this script.** No exceptions.
- **Index rebuilds are offline** on Standard/Express/WID editions (no
  `ONLINE = ON` — that's an Enterprise Edition feature). Sections 2 and 6
  will hold schema-modification locks that **block** concurrent access to
  the affected tables, including live WSUS console and IIS client scan
  traffic. Run during a real maintenance window; consider stopping the
  `WsusPool` IIS application pool first.
- **The script must run start-to-finish in a single, uninterrupted session.**
  Configuration (`SESSION_CONTEXT`) and logging (`#MaintenanceLog`,
  `#ErrorDetail`) are both session-scoped. A reconnect between batches
  (SSMS timeout, connection pooling, closing the query window) silently
  resets both.
- **Live decline of superseded updates is a two-flag opt-in** by design
  (`Susdb_DeclineTestRun = 0` **and** `Susdb_ConfirmLiveDecline = 1`). Always
  review the dry-run output first.
- If SUSDB is in **FULL** or **BULK_LOGGED** recovery model, batching the
  synchronization-history cleanup limits transaction size but does **not**
  by itself reclaim log space — ensure log backups are running during the
  cleanup, or expect the `.ldf` to grow.

## Quick start

```sql
-- 1. Connect to SUSDB with a db_owner login.
-- 2. Open sql/WSUS-SUSDB-Maintenance.sql in SSMS.
-- 3. Review and adjust Section 0 (configuration) for your environment.
--    Defaults are safe: everything destructive is off or dry-run.
-- 4. Execute the ENTIRE script top to bottom in one session (F5).
-- 5. Review the Section 7 output: run summary + per-item error detail.
```

See [docs/ADMIN-GUIDE.md](docs/ADMIN-GUIDE.md) for a full operational
walkthrough, and [examples/](examples/) for common configuration profiles.

## Configuration reference (SESSION_CONTEXT flags)

All configuration lives in Section 0 and is set via `sp_set_session_context`.
Nothing needs to be edited elsewhere in the script.

| Key | Default | Purpose |
|---|---|---|
| `Susdb_EnableTargetedReindex` | `1` | Enables Section 2 (fragmentation-driven reindex) |
| `Susdb_EnableFullRebuild` | `0` | Enables Section 6 (full rebuild — heavy) |
| `Susdb_ConfirmFullRebuild` | `0` | **Must also be `1`** for Section 6 to actually run |
| `Susdb_EnableSyncHistoryCleanup` | `1` | Enables Section 4 (purge old `tbEventInstance` rows) |
| `Susdb_EnableDeclineSuperseded` | `1` | Enables Section 5 (decline superseded updates) |
| `Susdb_DeclineTestRun` | `1` | `1` = dry run (safe, default). `0` = attempt real declines |
| `Susdb_ConfirmLiveDecline` | `0` | **Must also be `1`** (with `DeclineTestRun = 0`) for a real decline to happen |
| `Susdb_DeclineThresholdDays` | `30` | Age threshold for declining superseded updates — must match your SUP supersedence rule configuration |
| `Susdb_FullScanStatistics` | `0` | `0` = fast `sp_updatestats`. `1` = full `FULLSCAN` pass (slow, thorough) |
| `Susdb_RebuildFillFactor` | `90` | Fill factor applied to qualifying index rebuilds |
| `Susdb_RebuildMaxDop` | `NULL` | `NULL` = server default. Set to `1`–`2` on constrained WID VMs |
| `Susdb_SyncHistoryBatchSize` | `5000` | Row count per DELETE batch during history cleanup |
| `Susdb_CheckpointEveryNBatches` | `20` | Throttles `CHECKPOINT` frequency during history cleanup |

## What each section does

| Section | Name | Default | What it does |
|---|---|---|---|
| 0 | Configuration | — | Sets all `SESSION_CONTEXT` flags, creates `#MaintenanceLog` and `#ErrorDetail` |
| 1 | Environment validation | Always runs | Detects engine version, safely raises SUSDB compatibility level if needed |
| 2 | Targeted reindex | ON | Reorganizes/rebuilds only the indexes that meet Microsoft's published fragmentation thresholds |
| 3 | Update statistics | Always runs | `sp_updatestats` by default, or full `FULLSCAN` if configured |
| 4 | Sync history cleanup | ON | Batched purge of old `tbEventInstance` rows so the WSUS console stops timing out |
| 5 | Decline superseded updates | ON (dry run) | Declines updates superseded and older than the configured threshold |
| 6 | Full index rebuild | OFF | Rebuilds every index on every table — opt-in only, for severely degraded databases |
| 7 | Run summary | Always runs | Queryable summary of every step, plus persisted per-item error detail |

## Usage examples

See [examples/](examples/) for ready-to-use configuration profiles:

- [`examples/diagnose-only.md`](examples/diagnose-only.md) — read-only checks, no changes
- [`examples/routine-maintenance.md`](examples/routine-maintenance.md) — safe defaults for a recurring maintenance window
- [`examples/severely-degraded-susdb.md`](examples/severely-degraded-susdb.md) — full rebuild + live decline, for a SUSDB that's never had maintenance

## Reading the results

Section 7 returns three result sets:

1. **Per-step summary** — one row per section, with `Status`
   (`Success` / `CompletedWithErrors` / `Failed` / `Skipped`), row counts, and
   duration.
2. **Total run duration**.
3. **`#ErrorDetail`** — every individual failure (specific index, table, or
   `UpdateID`) with its error message. Query this whenever a step shows
   `CompletedWithErrors`.

## Best practices

- Always run Section 0 immediately before the rest of the script, in the
  same session — never assume a previous session's configuration carried
  over.
- Run with all defaults first (dry run, targeted reindex only) to establish
  a baseline before enabling heavier options.
- Schedule Sections 2 and 6 outside business hours; consider stopping
  `WsusPool` first.
- Re-run Section 3 (statistics) after a large Section 5 decline pass.
- Keep the `#ErrorDetail` output from every production run for your change
  record.

## Known limitations

- Configuration and logging are session-scoped (see warnings above) — there
  is intentionally no permanent table added to SUSDB.
- The superseded-update decline step calls a WSUS stored procedure
  (`spDeclineUpdate`) row by row; there is no supported set-based
  alternative, so at very large backlogs (tens/hundreds of thousands of
  updates) this step can take hours regardless of tuning.
- Index rebuilds are offline on non-Enterprise editions — this is a SQL
  Server edition limitation, not something this script can work around.

## FAQ

**Does this replace the WSUS Server Cleanup Wizard?**
No — run this alongside it. The Cleanup Wizard handles obsolete
updates/computers; this script handles database-level index/statistics
health and superseded-update decline.

**Can I run this on a WSUS replica server?**
The decline logic preserves `@failIfReplica = 1`, so declines will fail
safely (and be logged in `#ErrorDetail`) rather than silently succeeding
somewhere they shouldn't.

**Will this work on Azure SQL Database?**
No — WSUS/SUSDB is not a supported configuration on Azure SQL Database.
This script targets on-premises SQL Server and WID only.

**Do I need to run every section every time?**
No. Sections 2, 4, 5, and 6 are independently toggleable. A typical routine
run only needs Sections 1–5 with default settings.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Could not find stored procedure 'sp_set_session_context'` | Engine older than SQL Server 2016 | Not supported — see [Supported versions](#supported-versions) |
| Section 3 unexpectedly runs a slow FULLSCAN | Section 0 wasn't run in the same session | Re-run the entire script from Section 0 in one uninterrupted session |
| Section 5 shows `TestRun=1` even though you set `DeclineTestRun = 0` | `Susdb_ConfirmLiveDecline` wasn't also set to `1` | Set both flags in Section 0 |
| Section 6 shows `Skipped` even though `EnableFullRebuild = 1` | `Susdb_ConfirmFullRebuild` wasn't also set to `1` | Set both flags in Section 0 |
| WSUS console/clients time out **during** the script run | Offline index rebuild holding a lock | Expected — run during a maintenance window; wait for the section to complete |

## Microsoft Learn references

- [Reindex the WSUS database](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/reindex-the-wsus-database)
- [WSUS maintenance guide for Configuration Manager](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/wsus-maintenance-guide)
- [Reorganize and rebuild indexes](https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes)
- [ALTER DATABASE ... SET COMPATIBILITY_LEVEL](https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level)
- [Troubleshoot WSUS high CPU usage](https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/troubleshoot-wsus-server-high-cpu-usage)

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
guidelines, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community
standards. Security issues should be reported per [SECURITY.md](SECURITY.md),
not as public issues.

## Credits

Authored and maintained by **Brahim O.** — Azure / Identity & Security
Consultant. Built on top of Microsoft's officially published WSUS reindex
script, extended with production-hardening informed by Microsoft Learn's
current index-maintenance and compatibility-level guidance.
