# Example: diagnose only, no changes

Use this profile to understand the state of SUSDB before deciding what to
run. It only enables the always-on validation/statistics sections and skips
every optional write operation.

```sql
EXEC sp_set_session_context @key = N'Susdb_EnableTargetedReindex',     @value = 0;
EXEC sp_set_session_context @key = N'Susdb_EnableFullRebuild',        @value = 0;
EXEC sp_set_session_context @key = N'Susdb_ConfirmFullRebuild',       @value = 0;
EXEC sp_set_session_context @key = N'Susdb_EnableSyncHistoryCleanup', @value = 0;
EXEC sp_set_session_context @key = N'Susdb_EnableDeclineSuperseded',  @value = 1; -- dry run only
EXEC sp_set_session_context @key = N'Susdb_DeclineTestRun',           @value = 1;
EXEC sp_set_session_context @key = N'Susdb_ConfirmLiveDecline',       @value = 0;
EXEC sp_set_session_context @key = N'Susdb_FullScanStatistics',       @value = 0;
```

What you get: current compatibility level, index fragmentation candidates
(printed, not acted on if you also set `Susdb_EnableTargetedReindex = 0`),
a `sp_updatestats` pass, and a **count** of how many superseded updates
would be declined — without declining any of them.
