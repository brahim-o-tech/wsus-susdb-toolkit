# Administrator Guide

This guide is written for a systems administrator who needs to operate this
script without reading the T-SQL source in detail. For flag-by-flag
reference, see the main [README.md](../README.md#configuration-reference-session_context-flags).

## 1. When to run this script

| Symptom | Run it? |
|---|---|
| SCCM `wsyncmgr.log` shows `WSUS server not responding` / sync timeouts | Yes |
| WSUS console freezes opening "All Updates" or "Synchronizations" | Yes |
| `wsusutil.exe checkhealth` times out | Yes |
| Windows Server Update Services Event IDs 12002 / 12022 / 12042 | Yes |
| Routine monthly/quarterly maintenance, no symptoms | Yes — with default (light) settings |
| Everything is healthy, no complaints, ran maintenance last week | No — don't run for the sake of running it; index rebuilds carry real locking cost |

Before running this script at all, confirm the symptom is actually a SUSDB
problem and not network, IIS, or certificate related. See the companion
diagnostic checklist document (troubleshooting doc) referenced from the
project's article for the full pre-flight checklist.

## 2. Which sections to enable, by scenario

| Scenario | Section 2 (reindex) | Section 4 (history cleanup) | Section 5 (decline) | Section 6 (full rebuild) |
|---|---|---|---|---|
| Routine monthly maintenance | ON | ON | ON (dry run → live) | OFF |
| Console times out on Synchronizations node | ON | ON (priority) | ON | OFF unless still bad after |
| SUSDB never maintained, severely degraded | ON | ON | ON | ON (double opt-in) |
| Just want a health check | OFF | OFF | ON (dry run only) | OFF |
| Post-decline cleanup | OFF (already done) | OFF | OFF | OFF — just re-run Section 3 with `FullScanStatistics = 1` |

## 3. Before running — checklist

- [ ] Full backup of SUSDB completed and verified restorable
- [ ] Maintenance window confirmed and communicated (index rebuilds block
      concurrent access)
- [ ] `WsusPool` IIS application pool stopped (recommended for Sections 2/6)
- [ ] Confirmed login has `db_owner` on SUSDB
- [ ] Confirmed you're connecting to the correct instance/database
      (`SELECT @@SERVERNAME, DB_NAME();`)
- [ ] Section 0 configuration reviewed line by line — don't assume the
      defaults from a previous run
- [ ] For a live decline: dry-run count reviewed and looks reasonable
      relative to your environment's update volume

## 4. After running — checklist

- [ ] Section 7 summary reviewed — any `Failed` or `CompletedWithErrors`?
- [ ] If `CompletedWithErrors`, queried `#ErrorDetail` for specifics (note:
      this is a temp table — capture the output **before** closing the
      session, or re-run the Section 7 queries while still connected)
- [ ] `WsusPool` restarted if it was stopped
- [ ] SCCM software update point sync triggered and `wsyncmgr.log` checked
      for successful completion
- [ ] WSUS console reopened and confirmed responsive
- [ ] Change record updated with the Section 7 summary output

## 5. Risks

| Risk | Mitigation already built in | Residual risk you own |
|---|---|---|
| Accidental mass decline of updates | Two-flag confirmation gate, dry-run default | You still need to actually review the dry-run count before flipping the flags |
| Blocking production WSUS traffic during rebuild | Explicit warnings in script output | You need to schedule the window and communicate it |
| Transaction log growth during history cleanup | Batching + throttled CHECKPOINT | Under FULL recovery model, you must ensure log backups are running |
| Losing the run's error detail | Persisted `#ErrorDetail` table | It's session-scoped — copy the output before disconnecting |
| Running on an unsupported engine | Hard fail at Section 0 with a clear message | None — this is handled |

## 6. Interpreting the results

Section 7 returns:

1. **Step summary** — `Status` column meanings:
   - `Success` — completed with zero errors
   - `CompletedWithErrors` — completed, but check `#ErrorDetail`
   - `Failed` — the step itself failed (fatal, caught by the outer
     `TRY...CATCH`); check `Detail` column for the error message
   - `Skipped` — disabled by configuration (check `Detail` for why —
     including the two-flag gates for Sections 5 and 6)
2. **Total run duration**.
3. **`#ErrorDetail`** — one row per individual failure with the specific
   object/UpdateID and error text. Empty result set = no individual
   failures occurred.

A healthy routine run typically shows all `Success` except Sections 5/6
showing `Skipped` if you didn't confirm a live decline or full rebuild.
