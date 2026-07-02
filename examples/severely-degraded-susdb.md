# Example: severely degraded SUSDB (never maintained)

Use this profile only for a SUSDB that has never had maintenance performed
and is causing console timeouts / SCCM sync failures, where Section 2's
targeted reindex alone is not expected to be enough. **Run only during a
confirmed maintenance window, with WsusPool stopped, and after a verified
backup.**

```sql
EXEC sp_set_session_context @key = N'Susdb_EnableTargetedReindex',     @value = 1;
EXEC sp_set_session_context @key = N'Susdb_EnableFullRebuild',        @value = 1;
EXEC sp_set_session_context @key = N'Susdb_ConfirmFullRebuild',       @value = 1; -- explicit, deliberate opt-in
EXEC sp_set_session_context @key = N'Susdb_EnableSyncHistoryCleanup', @value = 1;
EXEC sp_set_session_context @key = N'Susdb_SyncHistoryBatchSize',     @value = 2000; -- smaller batches, this table is likely huge
EXEC sp_set_session_context @key = N'Susdb_EnableDeclineSuperseded',  @value = 1;
EXEC sp_set_session_context @key = N'Susdb_DeclineTestRun',           @value = 1; -- ALWAYS dry-run first, even here
EXEC sp_set_session_context @key = N'Susdb_ConfirmLiveDecline',       @value = 0;
EXEC sp_set_session_context @key = N'Susdb_FullScanStatistics',       @value = 1; -- worth the cost after this much churn
EXEC sp_set_session_context @key = N'Susdb_RebuildMaxDop',            @value = 2; -- protect a constrained WID VM
```

**Expect this run to take a long time** (potentially hours) if the decline
backlog is large — the decline step calls a WSUS stored procedure once per
update and cannot be parallelized. Consider splitting the live decline into
its own, separate maintenance window from the full rebuild.
