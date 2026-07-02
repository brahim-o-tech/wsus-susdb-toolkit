# Example: routine maintenance window

The recommended profile for a recurring maintenance window (e.g. monthly,
after Patch Tuesday cleanup) on a SUSDB that already receives regular care.
This is the **default configuration shipped in the script** — shown here
explicitly for clarity.

```sql
EXEC sp_set_session_context @key = N'Susdb_EnableTargetedReindex',     @value = 1;
EXEC sp_set_session_context @key = N'Susdb_EnableFullRebuild',        @value = 0;
EXEC sp_set_session_context @key = N'Susdb_ConfirmFullRebuild',       @value = 0;
EXEC sp_set_session_context @key = N'Susdb_EnableSyncHistoryCleanup', @value = 1;
EXEC sp_set_session_context @key = N'Susdb_EnableDeclineSuperseded',  @value = 1;
EXEC sp_set_session_context @key = N'Susdb_DeclineTestRun',           @value = 1; -- review dry run first
EXEC sp_set_session_context @key = N'Susdb_ConfirmLiveDecline',       @value = 0;
EXEC sp_set_session_context @key = N'Susdb_DeclineThresholdDays',     @value = 30;
EXEC sp_set_session_context @key = N'Susdb_FullScanStatistics',       @value = 0;
```

**Workflow:**
1. Run the full script with the above (dry run for decline).
2. Review Section 7 output, especially the decline dry-run count.
3. If the count looks reasonable, re-run **just Section 0 and Section 5**
   with `Susdb_DeclineTestRun = 0` and `Susdb_ConfirmLiveDecline = 1` in the
   same session to perform the real decline.
4. Re-run Section 3 (statistics) afterward if a large number of updates
   were declined.
