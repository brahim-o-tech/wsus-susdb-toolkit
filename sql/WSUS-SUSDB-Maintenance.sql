/* =============================================================================
   WSUS / SUSDB MAINTENANCE SCRIPT — HARDENED VERSION
   Version 1.0.0 — https://github.com/brahim-o-tech/wsus-susdb-toolkit
   Licensed under the MIT License — see LICENSE in the repository root.
   =============================================================================
   Purpose : Restore a bloated/unresponsive WSUS database (SUSDB) to a healthy
             state and re-establish reliable SCCM/MECM <-> WSUS synchronization.

   Compatible with : SQL Server Standard/Express 2016, 2017, 2019, 2022, 2025
                      and Windows Internal Database (WID).

   Design principles applied in this revision:
     - No undocumented system procedures (sp_MSforeachtable / sp_MSforeachdb)
       -> replaced with documented catalog views (sys.tables) + dynamic SQL.
     - Every destructive/expensive step is OPTIONAL and OFF by default unless
       explicitly enabled via session-context flags (section 0).
     - TRY...CATCH around every critical operation; failures are logged, not
       fatal to the whole run (except where a hard stop is safer).
     - Execution time + row counts captured per step in #MaintenanceLog.
     - Compatibility level is DETECTED from the running SQL Server engine and
       only ever raised (never forced down, never changed if already correct).
     - Large deletes (sync history) are batched to control transaction log
       growth, especially important on WID / Simple recovery model instances.
     - Superseded-update decline logic keeps its cursor (spDeclineUpdate is a
       business-logic stored procedure with side effects — it cannot safely
       be rewritten as a set-based statement), but the cursor is declared
       LOCAL FAST_FORWARD READ_ONLY, wrapped per-row in TRY...CATCH so one
       failure doesn't abort the whole batch, and progress is logged.

   References:
     - Reindex the WSUS database (Microsoft Learn):
       https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/reindex-the-wsus-database
     - WSUS maintenance guide for Configuration Manager (Microsoft Learn):
       https://learn.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/wsus-maintenance-guide
     - Reorganize and rebuild indexes (Microsoft Learn) — current guidance
       explicitly states thresholds are a starting point, not a fixed rule,
       and that much of the benefit of a rebuild comes from the statistics
       refresh, not the defragmentation itself:
       https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes
     - ALTER DATABASE ... SET COMPATIBILITY_LEVEL (Microsoft Learn):
       https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level
     - sp_MSforeachtable is an undocumented, unsupported procedure that Microsoft
       can change or remove without notice, and known cursor-related bugs can
       cause it to silently skip objects — avoided in this revision.

   IMPORTANT: Take a full backup of SUSDB before running this script. Run
   Section 0 first and review the output, then enable only the sections you
   actually need.
   ============================================================================= */


/* =============================================================================
   SECTION 0 — CONFIGURATION (run first, once per session)
   =============================================================================
   Flags are stored in SESSION_CONTEXT (SQL Server 2016+, documented, and
   survives across GO batches within the same connection — unlike local
   variables, which reset at every GO). Adjust the values below, then run
   this batch before anything else.
   ============================================================================= */
/* ---- Engine version guard (v2) -------------------------------------------
   SESSION_CONTEXT / sp_set_session_context require SQL Server 2016 (13.x) or
   later. WID tracks the engine shipped with the host Windows Server release;
   older WSUS boxes (e.g. still on a pre-2016-vintage WID) will otherwise fail
   later with a cryptic "could not find stored procedure" error. Fail fast
   with a clear message instead.
   --------------------------------------------------------------------------- */
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 13
BEGIN
    RAISERROR('This script requires SQL Server 2016 (engine version 13.x) or later — SESSION_CONTEXT is not available on this instance. Detected ProductMajorVersion: %s.', 20, 1, @@VERSION) WITH LOG;
    -- Severity 20 forces the connection to close, guaranteeing a hard stop
    -- instead of continuing into batches that will fail unpredictably.
END
GO

USE SUSDB;
GO

EXEC sp_set_session_context @key = N'Susdb_EnableTargetedReindex',     @value = 1;   -- Section 2: light reindex based on fragmentation (recommended default)
EXEC sp_set_session_context @key = N'Susdb_EnableFullRebuild',        @value = 0;   -- Section 6: full ALTER INDEX ALL ... REBUILD on every table (heavy — opt-in only)
EXEC sp_set_session_context @key = N'Susdb_ConfirmFullRebuild',       @value = 0;   -- Must ALSO be 1 for Section 6 to run — second key prevents accidental heavy runs from stale config
EXEC sp_set_session_context @key = N'Susdb_EnableSyncHistoryCleanup', @value = 1;   -- Section 4: purge old tbEventInstance rows
EXEC sp_set_session_context @key = N'Susdb_EnableDeclineSuperseded',  @value = 1;   -- Section 5: decline superseded updates
EXEC sp_set_session_context @key = N'Susdb_DeclineTestRun',           @value = 1;   -- 1 = dry run (default, safe). Set to 0 only after reviewing the dry-run output.
EXEC sp_set_session_context @key = N'Susdb_ConfirmLiveDecline',       @value = 0;   -- Must ALSO be 1 (with DeclineTestRun = 0) for Section 5 to actually decline anything
EXEC sp_set_session_context @key = N'Susdb_DeclineThresholdDays',     @value = 30;  -- Must match SUP supersedence rule configuration in ConfigMgr
EXEC sp_set_session_context @key = N'Susdb_FullScanStatistics',       @value = 0;   -- 0 = sp_updatestats (fast, only refreshes stale stats). 1 = FULLSCAN on every table (slow, thorough)
EXEC sp_set_session_context @key = N'Susdb_RebuildFillFactor',        @value = 90;  -- Applied only to indexes that qualify for REBUILD with a large row count
EXEC sp_set_session_context @key = N'Susdb_RebuildMaxDop',            @value = NULL;-- NULL = server default. Set to 1-2 on constrained WID VMs to avoid saturating available workers during a rebuild.
EXEC sp_set_session_context @key = N'Susdb_SyncHistoryBatchSize',     @value = 5000;-- Batch size for the tbEventInstance purge (controls log growth)
EXEC sp_set_session_context @key = N'Susdb_CheckpointEveryNBatches',  @value = 20;  -- Throttle: CHECKPOINT is a database-wide flush — don't issue it after every single batch
GO

-- #MaintenanceLog persists for the lifetime of this session across all GO
-- batches below. Query it at the end for the full run summary (Section 7).
IF OBJECT_ID('tempdb..#MaintenanceLog') IS NOT NULL DROP TABLE #MaintenanceLog;
CREATE TABLE #MaintenanceLog
(
    StepId          INT IDENTITY(1,1) PRIMARY KEY,
    StepName        NVARCHAR(100)   NOT NULL,
    StartTimeUtc    DATETIME2(3)    NOT NULL,
    EndTimeUtc      DATETIME2(3)    NULL,
    RowsAffected    INT             NULL,
    Status          NVARCHAR(20)    NOT NULL DEFAULT ('Running'),
    Detail          NVARCHAR(4000)  NULL
);
GO

-- #ErrorDetail (v2): persists individual per-item failures from Sections 2, 5
-- and 6. #MaintenanceLog only ever carries an aggregate error count — without
-- this, the specific object/UpdateID behind a failure is only ever PRINTed,
-- and is lost the moment the SSMS/sqlcmd session is closed.
IF OBJECT_ID('tempdb..#ErrorDetail') IS NOT NULL DROP TABLE #ErrorDetail;
CREATE TABLE #ErrorDetail
(
    ErrorId         INT IDENTITY(1,1) PRIMARY KEY,
    StepName        NVARCHAR(100)   NOT NULL,
    ItemKey         NVARCHAR(200)   NULL,
    ErrorMessage    NVARCHAR(4000)  NOT NULL,
    ErrorTimeUtc    DATETIME2(3)    NOT NULL DEFAULT (SYSUTCDATETIME())
);
GO

PRINT '=== Configuration loaded. Review SESSION_CONTEXT flags above before proceeding. ===';
GO


/* =============================================================================
   SECTION 1 — ENVIRONMENT VALIDATION & COMPATIBILITY LEVEL
   =============================================================================
   Detects the running SQL Server major version and only RAISES the database
   compatibility level if it is currently lower than what the engine supports.
   Never forces a fixed value (e.g. 130) blindly, and never downgrades.
   Reference: https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level
   ============================================================================= */
DECLARE @StepStart DATETIME2(3) = SYSUTCDATETIME();
INSERT INTO #MaintenanceLog (StepName, StartTimeUtc) VALUES ('EnvironmentValidation', @StepStart);
DECLARE @LogId INT = SCOPE_IDENTITY();  -- v2: captured immediately, never recomputed later in this batch

BEGIN TRY
    DECLARE @ProductMajorVersion INT = CAST(SERVERPROPERTY('ProductMajorVersion') AS INT);
    DECLARE @Edition NVARCHAR(128)   = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128));
    DECLARE @CurrentCompatLevel INT  = (SELECT compatibility_level FROM sys.databases WHERE name = 'SUSDB');
    DECLARE @RecommendedCompatLevel INT;

    -- v2: if @CurrentCompatLevel couldn't be resolved (permissions, name
    -- mismatch), stop here with a clear message instead of silently
    -- reporting "already correct" via a NULL comparison.
    IF @CurrentCompatLevel IS NULL
    BEGIN
        PRINT 'WARNING: Could not read compatibility_level for SUSDB from sys.databases (permissions or name mismatch?). Skipping compatibility level check.';
        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Skipped', Detail = 'Could not resolve current compatibility level'
        WHERE StepId = @LogId;
        RETURN;
    END

    -- Map engine major version -> highest supported compatibility level.
    -- 13 = SQL Server 2016, 14 = 2017, 15 = 2019, 16 = 2022, 17 = 2025.
    -- Verified against Microsoft Learn (ALTER DATABASE ... COMPATIBILITY_LEVEL).
    SET @RecommendedCompatLevel =
        CASE @ProductMajorVersion
            WHEN 13 THEN 130
            WHEN 14 THEN 140
            WHEN 15 THEN 150
            WHEN 16 THEN 160
            WHEN 17 THEN 170
            ELSE @CurrentCompatLevel  -- Unknown/older engine: leave untouched, don't guess
        END;

    PRINT 'SQL Server edition       : ' + @Edition;
    PRINT 'SQL Server major version : ' + CAST(@ProductMajorVersion AS NVARCHAR(10));
    PRINT 'SUSDB current compat lvl : ' + CAST(@CurrentCompatLevel AS NVARCHAR(10));
    PRINT 'Recommended compat lvl   : ' + CAST(@RecommendedCompatLevel AS NVARCHAR(10));

    IF @RecommendedCompatLevel > @CurrentCompatLevel
    BEGIN
        -- ALTER DATABASE cannot run inside an explicit multi-statement
        -- transaction — do not wrap this section in BEGIN TRAN if modified later.
        DECLARE @sql NVARCHAR(200) = N'ALTER DATABASE SUSDB SET COMPATIBILITY_LEVEL = ' + CAST(@RecommendedCompatLevel AS NVARCHAR(10));
        EXEC (@sql);
        PRINT 'Compatibility level raised from ' + CAST(@CurrentCompatLevel AS NVARCHAR(10)) + ' to ' + CAST(@RecommendedCompatLevel AS NVARCHAR(10)) + '.';
    END
    ELSE
    BEGIN
        PRINT 'Compatibility level already at or above the recommended value — no change made.';
    END

    UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Success',
        Detail = 'Current=' + CAST(@CurrentCompatLevel AS NVARCHAR(10)) + ', Recommended=' + CAST(@RecommendedCompatLevel AS NVARCHAR(10))
    WHERE StepId = @LogId;
END TRY
BEGIN CATCH
    UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Failed', Detail = ERROR_MESSAGE()
    WHERE StepId = @LogId;
    PRINT 'ERROR in EnvironmentValidation: ' + ERROR_MESSAGE();
END CATCH
GO


/* =============================================================================
   SECTION 2 — TARGETED REINDEX (fragmentation-driven, recommended default)
   =============================================================================
   This is the original Microsoft reindex logic (from the Reindex the WSUS
   Database article), preserved because it is still the officially published
   script for SUSDB — but wrapped in TRY...CATCH per index so a single
   failure doesn't stop the whole pass, and counters are logged.

   Note on thresholds: Microsoft's current index-maintenance guidance says
   fragmentation/page-density thresholds are a starting point, not a fixed
   rule, and that a large share of the benefit from REBUILD comes from the
   statistics refresh rather than defragmentation itself. The thresholds
   below (matching the original MS WSUS script) are left intact since they
   are the values Microsoft ships specifically for SUSDB maintenance.
   ============================================================================= */
IF CAST(SESSION_CONTEXT(N'Susdb_EnableTargetedReindex') AS BIT) = 1
BEGIN
    DECLARE @StepStart DATETIME2(3) = SYSUTCDATETIME();
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc) VALUES ('TargetedReindex', @StepStart);
    DECLARE @LogId INT = SCOPE_IDENTITY();  -- v2: captured immediately

    -- v2 operational note: ALTER INDEX REBUILD is OFFLINE on Standard/Express/
    -- WID (ONLINE=ON requires Enterprise Edition). It takes a Sch-M lock that
    -- BLOCKS all access to the table for the rebuild's duration, including
    -- live WSUS console / IIS client scan traffic. Run this during a real
    -- maintenance window, ideally with the WsusPool app pool stopped.
    PRINT 'NOTE: REBUILD operations below are offline and will block concurrent access to the affected table. Run during a maintenance window.';

    BEGIN TRY
        SET NOCOUNT ON;

        -- v2: object/schema/index names resolved once, up front, in the same
        -- set-based query that identifies candidate indexes — avoids two
        -- extra catalog lookups PER INDEX inside the cursor loop (N+1 pattern
        -- in the original Microsoft script, preserved unchanged until now).
        DECLARE @work_to_do TABLE (
            objectid        INT,
            indexid         INT,
            schemaname      NVARCHAR(130),
            objectname      NVARCHAR(130),
            indexname       NVARCHAR(130),
            pagedensity     FLOAT,
            fragmentation   FLOAT,
            numrows         INT,
            fillfactorset   BIT
        );

        DECLARE @FillFactor INT = CAST(SESSION_CONTEXT(N'Susdb_RebuildFillFactor') AS INT);
        DECLARE @MaxDop INT = CAST(SESSION_CONTEXT(N'Susdb_RebuildMaxDop') AS INT); -- NULL = server default
        DECLARE @RebuiltCount INT = 0, @ReorganizedCount INT = 0, @ErrorCount INT = 0;

        INSERT INTO @work_to_do (objectid, indexid, schemaname, objectname, indexname, pagedensity, fragmentation, numrows, fillfactorset)
        SELECT
            f.object_id, f.index_id,
            QUOTENAME(s.name), QUOTENAME(o.name), QUOTENAME(i.name),
            f.avg_page_space_used_in_percent, f.avg_fragmentation_in_percent, f.record_count,
            CASE i.fill_factor WHEN 0 THEN 0 ELSE 1 END
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') AS f
        INNER JOIN sys.indexes AS i ON f.object_id = i.object_id AND f.index_id = i.index_id
        INNER JOIN sys.objects AS o ON f.object_id = o.object_id
        INNER JOIN sys.schemas AS s ON o.schema_id = s.schema_id
        WHERE i.index_id > 0  -- exclude heaps
          AND (
                (f.avg_page_space_used_in_percent < 85.0 AND f.avg_page_space_used_in_percent / 100.0 * f.page_count < f.page_count - 1)
                OR (f.page_count > 50 AND f.avg_fragmentation_in_percent > 15.0)
                OR (f.page_count > 10 AND f.avg_fragmentation_in_percent > 80.0)
              );

        PRINT 'Indexes selected for maintenance: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

        DECLARE @objectid INT, @indexid INT, @density FLOAT, @fragmentation FLOAT, @numrows INT;
        DECLARE @schemaname NVARCHAR(130), @objectname NVARCHAR(130), @indexname NVARCHAR(130);
        DECLARE @fillfactorset BIT, @command NVARCHAR(4000);

        DECLARE curIndexes CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
            SELECT objectid, indexid, schemaname, objectname, indexname, pagedensity, fragmentation, numrows, fillfactorset FROM @work_to_do;

        OPEN curIndexes;
        FETCH NEXT FROM curIndexes INTO @objectid, @indexid, @schemaname, @objectname, @indexname, @density, @fragmentation, @numrows, @fillfactorset;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                IF ((@density BETWEEN 75.0 AND 85.0) AND @fillfactorset = 1) OR (@fragmentation < 30.0)
                BEGIN
                    SET @command = N'ALTER INDEX ' + @indexname + N' ON ' + @schemaname + N'.' + @objectname + N' REORGANIZE';
                    SET @ReorganizedCount += 1;
                END
                ELSE IF @numrows >= 5000 AND @fillfactorset = 0
                BEGIN
                    SET @command = N'ALTER INDEX ' + @indexname + N' ON ' + @schemaname + N'.' + @objectname
                        + N' REBUILD WITH (FILLFACTOR = ' + CAST(@FillFactor AS NVARCHAR(10))
                        + CASE WHEN @MaxDop IS NOT NULL THEN N', MAXDOP = ' + CAST(@MaxDop AS NVARCHAR(3)) ELSE N'' END + N')';
                    SET @RebuiltCount += 1;
                END
                ELSE
                BEGIN
                    SET @command = N'ALTER INDEX ' + @indexname + N' ON ' + @schemaname + N'.' + @objectname + N' REBUILD'
                        + CASE WHEN @MaxDop IS NOT NULL THEN N' WITH (MAXDOP = ' + CAST(@MaxDop AS NVARCHAR(3)) + N')' ELSE N'' END;
                    SET @RebuiltCount += 1;
                END

                PRINT CONVERT(NVARCHAR, GETDATE(), 121) + N' Executing: ' + @command;
                EXEC (@command);
            END TRY
            BEGIN CATCH
                SET @ErrorCount += 1;
                INSERT INTO #ErrorDetail (StepName, ItemKey, ErrorMessage)
                VALUES ('TargetedReindex', @schemaname + N'.' + @objectname + N' / ' + @indexname, ERROR_MESSAGE());
                PRINT 'ERROR reindexing object_id=' + CAST(@objectid AS NVARCHAR(10))
                    + ', index_id=' + CAST(@indexid AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
            END CATCH

            FETCH NEXT FROM curIndexes INTO @objectid, @indexid, @schemaname, @objectname, @indexname, @density, @fragmentation, @numrows, @fillfactorset;
        END

        CLOSE curIndexes;
        DEALLOCATE curIndexes;

        PRINT 'Rebuilt: ' + CAST(@RebuiltCount AS NVARCHAR(10))
            + ' | Reorganized: ' + CAST(@ReorganizedCount AS NVARCHAR(10))
            + ' | Errors: ' + CAST(@ErrorCount AS NVARCHAR(10));

        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = CASE WHEN @ErrorCount = 0 THEN 'Success' ELSE 'CompletedWithErrors' END,
            RowsAffected = @RebuiltCount + @ReorganizedCount,
            Detail = 'Rebuilt=' + CAST(@RebuiltCount AS NVARCHAR(10)) + ', Reorganized=' + CAST(@ReorganizedCount AS NVARCHAR(10)) + ', Errors=' + CAST(@ErrorCount AS NVARCHAR(10))
        WHERE StepId = @LogId;
    END TRY
    BEGIN CATCH
        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Failed', Detail = ERROR_MESSAGE()
        WHERE StepId = @LogId;
        PRINT 'FATAL ERROR in TargetedReindex: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc, EndTimeUtc, Status, Detail)
    VALUES ('TargetedReindex', SYSUTCDATETIME(), SYSUTCDATETIME(), 'Skipped', 'Disabled via SESSION_CONTEXT');
    PRINT 'TargetedReindex skipped (disabled).';
END
GO


/* =============================================================================
   SECTION 3 — UPDATE STATISTICS
   =============================================================================
   Default: sp_updatestats — a documented system procedure that updates
   statistics only for tables/indexes with data modifications since the last
   update, using its own internal sampling. This is materially cheaper than a
   blanket FULLSCAN and is sufficient for routine maintenance.

   Optional: set Susdb_FullScanStatistics = 1 for a full, accurate pass
   (e.g. right after a large superseded-updates decline run, or once a
   quarter) — this replaces the undocumented sp_msforeachtable FULLSCAN loop
   with a documented, catalog-driven equivalent.
   ============================================================================= */
DECLARE @StepStart DATETIME2(3) = SYSUTCDATETIME();
INSERT INTO #MaintenanceLog (StepName, StartTimeUtc) VALUES ('UpdateStatistics', @StepStart);
DECLARE @LogId INT = SCOPE_IDENTITY();  -- v2: captured immediately

BEGIN TRY
    -- v2 CRITICAL FIX: the original "IF @FullScan = 0" comparison evaluates
    -- to UNKNOWN (not TRUE) when @FullScan is NULL — e.g. Section 0 was never
    -- run in this session/connection — which fell through to the ELSE branch
    -- and silently ran the EXPENSIVE FULLSCAN pass instead of the intended
    -- cheap default. ISNULL(...,0) guarantees NULL degrades to the safe,
    -- inexpensive path (sp_updatestats), never the heavy one.
    DECLARE @FullScan BIT = ISNULL(CAST(SESSION_CONTEXT(N'Susdb_FullScanStatistics') AS BIT), 0);
    DECLARE @StatsUpdated INT = 0;

    IF @FullScan = 0
    BEGIN
        PRINT 'Running sp_updatestats (refreshes only stale statistics)...';
        EXEC sp_updatestats;
        SET @StatsUpdated = -1; -- sp_updatestats doesn't return a per-table count
    END
    ELSE
    BEGIN
        PRINT 'Running full-scan statistics update on all user tables (documented catalog-driven loop, no sp_msforeachtable)...';
        DECLARE @tblSchema NVARCHAR(128), @tblName NVARCHAR(128), @statSql NVARCHAR(600);

        DECLARE curTables CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
            SELECT s.name, t.name
            FROM sys.tables t
            INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
            WHERE t.is_ms_shipped = 0 OR t.name LIKE 'tb%'; -- SUSDB tables are all first-party; guard kept for clarity

        OPEN curTables;
        FETCH NEXT FROM curTables INTO @tblSchema, @tblName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @statSql = N'UPDATE STATISTICS ' + QUOTENAME(@tblSchema) + N'.' + QUOTENAME(@tblName) + N' WITH FULLSCAN, COLUMNS';
                EXEC (@statSql);
                SET @StatsUpdated += 1;
            END TRY
            BEGIN CATCH
                INSERT INTO #ErrorDetail (StepName, ItemKey, ErrorMessage)
                VALUES ('UpdateStatistics', @tblSchema + N'.' + @tblName, ERROR_MESSAGE());
                PRINT 'ERROR updating statistics on ' + @tblSchema + N'.' + @tblName + ': ' + ERROR_MESSAGE();
            END CATCH
            FETCH NEXT FROM curTables INTO @tblSchema, @tblName;
        END

        CLOSE curTables;
        DEALLOCATE curTables;
    END

    PRINT 'Statistics update complete.';
    UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Success', RowsAffected = @StatsUpdated,
        Detail = CASE WHEN @FullScan = 1 THEN 'FULLSCAN mode' ELSE 'sp_updatestats (default sampling)' END
    WHERE StepId = @LogId;
END TRY
BEGIN CATCH
    UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Failed', Detail = ERROR_MESSAGE()
    WHERE StepId = @LogId;
    PRINT 'FATAL ERROR in UpdateStatistics: ' + ERROR_MESSAGE();
END CATCH
GO


/* =============================================================================
   SECTION 4 — SYNCHRONIZATION HISTORY CLEANUP (batched)
   =============================================================================
   Same intent as Microsoft's guidance (purge old tbEventInstance rows so the
   WSUS console stops timing out on the Synchronizations node), but the
   delete is batched instead of a single unbounded DELETE. A single massive
   DELETE against tbEventInstance can take an aggressive lock footprint and
   grow the transaction log significantly, especially problematic on WID
   (Simple recovery model, fixed local disk). Batching keeps each transaction
   small and lets the log reclaim space between batches (with periodic
   CHECKPOINT under Simple recovery model).
   ============================================================================= */
IF CAST(SESSION_CONTEXT(N'Susdb_EnableSyncHistoryCleanup') AS BIT) = 1
BEGIN
    DECLARE @StepStart DATETIME2(3) = SYSUTCDATETIME();
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc) VALUES ('SyncHistoryCleanup', @StepStart);
    DECLARE @LogId INT = SCOPE_IDENTITY();  -- v2: captured immediately

    DECLARE @RecoveryModel NVARCHAR(60) = (SELECT recovery_model_desc FROM sys.databases WHERE name = 'SUSDB');
    IF @RecoveryModel IN ('FULL', 'BULK_LOGGED')
        PRINT 'WARNING: SUSDB recovery model is ' + @RecoveryModel + '. Batching limits transaction size, but log space is only reclaimed by a log backup under this recovery model — ensure log backups are running during this cleanup, or monitor .ldf growth.';

    BEGIN TRY
        DECLARE @BatchSize INT = CAST(SESSION_CONTEXT(N'Susdb_SyncHistoryBatchSize') AS INT);
        DECLARE @CheckpointEvery INT = ISNULL(CAST(SESSION_CONTEXT(N'Susdb_CheckpointEveryNBatches') AS INT), 20);
        DECLARE @TotalDeleted INT = 0, @RowsThisBatch INT = 1, @BatchNumber INT = 0;

        WHILE @RowsThisBatch > 0
        BEGIN
            DELETE TOP (@BatchSize) FROM tbEventInstance
            WHERE EventNamespaceID = '2'
              AND EVENTID IN ('381', '382', '384', '386', '387', '389');

            SET @RowsThisBatch = @@ROWCOUNT;
            SET @TotalDeleted += @RowsThisBatch;
            SET @BatchNumber += 1;

            IF @RowsThisBatch > 0
            BEGIN
                PRINT CONVERT(NVARCHAR, GETDATE(), 121) + ' Deleted batch of ' + CAST(@RowsThisBatch AS NVARCHAR(10))
                    + ' rows (running total: ' + CAST(@TotalDeleted AS NVARCHAR(10)) + ').';

                -- v2: CHECKPOINT is a database-wide dirty-page flush, not a
                -- per-table operation — issuing it after every single batch
                -- (as v1 did) becomes a real I/O cost at millions-of-rows
                -- scale. Throttled to every Nth batch instead, and only under
                -- Simple recovery where it actually helps reclaim log space.
                IF @RecoveryModel = 'SIMPLE' AND @BatchNumber % @CheckpointEvery = 0
                    CHECKPOINT;
            END
        END

        IF @RecoveryModel = 'SIMPLE' CHECKPOINT; -- final flush after the loop exits

        PRINT 'Synchronization history cleanup complete. Total rows deleted: ' + CAST(@TotalDeleted AS NVARCHAR(10));
        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Success', RowsAffected = @TotalDeleted,
            Detail = 'RecoveryModel=' + @RecoveryModel
        WHERE StepId = @LogId;
    END TRY
    BEGIN CATCH
        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Failed', Detail = ERROR_MESSAGE()
        WHERE StepId = @LogId;
        PRINT 'FATAL ERROR in SyncHistoryCleanup: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc, EndTimeUtc, Status, Detail)
    VALUES ('SyncHistoryCleanup', SYSUTCDATETIME(), SYSUTCDATETIME(), 'Skipped', 'Disabled via SESSION_CONTEXT');
    PRINT 'SyncHistoryCleanup skipped (disabled).';
END
GO


/* =============================================================================
   SECTION 5 — DECLINE SUPERSEDED UPDATES
   =============================================================================
   Kept as a cursor deliberately: spDeclineUpdate is a stored procedure with
   business-side effects (it isn't a plain DML statement), so this cannot be
   rewritten as a single set-based UPDATE/DELETE without reimplementing WSUS
   internal logic — which is unsupported. Improvements over the original:
     - LOCAL FAST_FORWARD READ_ONLY cursor (cheaper than a default cursor).
     - Per-row TRY...CATCH: one failed decline (e.g. @failIfReplica conflict)
       no longer aborts the remaining batch.
     - Honors Susdb_DeclineTestRun (default 1 = dry run) and
       Susdb_DeclineThresholdDays from session context.
     - Progress is printed periodically instead of once per row, and success/
       failure counts are captured for the final summary.

   Edge cases handled:
     - Replica/downstream servers: @failIfReplica = 1 is preserved so the
       decline fails safely instead of silently succeeding somewhere it
       shouldn't on a replica WSUS server — the failure is now caught and
       logged instead of stopping the whole run.
     - Empty result set: cursor simply reports 0 processed, no error.
   ============================================================================= */
IF CAST(SESSION_CONTEXT(N'Susdb_EnableDeclineSuperseded') AS BIT) = 1
BEGIN
    DECLARE @StepStart DATETIME2(3) = SYSUTCDATETIME();
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc) VALUES ('DeclineSupersededUpdates', @StepStart);
    DECLARE @LogId INT = SCOPE_IDENTITY();  -- v2: captured immediately

    BEGIN TRY
        -- v2 safety gate: a real (non-test-run) decline pass requires BOTH
        -- Susdb_DeclineTestRun = 0 AND Susdb_ConfirmLiveDecline = 1. A single
        -- stale/copy-pasted flag can no longer trigger a live mass-decline.
        DECLARE @testRun BIT = ISNULL(CAST(SESSION_CONTEXT(N'Susdb_DeclineTestRun') AS BIT), 1); -- NULL defaults to safe dry-run
        DECLARE @confirmLive BIT = ISNULL(CAST(SESSION_CONTEXT(N'Susdb_ConfirmLiveDecline') AS BIT), 0);
        IF @testRun = 0 AND @confirmLive = 0
        BEGIN
            PRINT 'Susdb_DeclineTestRun = 0 but Susdb_ConfirmLiveDecline is not set to 1 — forcing this pass back to TEST RUN as a safety measure. Set both flags explicitly in Section 0 to perform a live decline.';
            SET @testRun = 1;
        END

        DECLARE @thresholdDays INT = CAST(SESSION_CONTEXT(N'Susdb_DeclineThresholdDays') AS INT);
        DECLARE @uid UNIQUEIDENTIFIER, @title NVARCHAR(500), @date DATETIME;
        DECLARE @userName NVARCHAR(100) = SYSTEM_USER;
        DECLARE @successCount INT = 0, @errorCount INT = 0, @totalCount INT = 0;
        DECLARE @LogInterval INT = 100;

        PRINT 'Declining superseded updates older than ' + CAST(@thresholdDays AS NVARCHAR(5))
            + ' days. Test run: ' + CASE @testRun WHEN 1 THEN 'YES (no changes will be made)' ELSE 'NO (updates will be declined)' END;

        DECLARE DU CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
            SELECT MU.UpdateID, U.DefaultTitle, U.CreationDate
            FROM vwMinimalUpdate MU
            JOIN PUBLIC_VIEWS.vUpdate U ON MU.UpdateID = U.UpdateId
            WHERE MU.IsSuperseded = 1
              AND MU.Declined = 0
              AND MU.IsLatestRevision = 1
              AND MU.CreationDate < DATEADD(DAY, -@thresholdDays, GETDATE())
            ORDER BY MU.CreationDate;

        OPEN DU;
        FETCH NEXT FROM DU INTO @uid, @title, @date;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @totalCount += 1;

            BEGIN TRY
                IF @testRun = 0
                BEGIN
                    EXEC spDeclineUpdate @updateID = @uid, @adminName = @userName, @failIfReplica = 1;
                END
                SET @successCount += 1;
            END TRY
            BEGIN CATCH
                SET @errorCount += 1;
                INSERT INTO #ErrorDetail (StepName, ItemKey, ErrorMessage)
                VALUES ('DeclineSupersededUpdates', CAST(@uid AS NVARCHAR(50)) + N' - ' + @title, ERROR_MESSAGE());
                PRINT 'ERROR declining update ' + CAST(@uid AS NVARCHAR(50)) + ' (' + @title + '): ' + ERROR_MESSAGE();
            END CATCH

            IF @totalCount % @LogInterval = 0
                PRINT CONVERT(NVARCHAR, GETDATE(), 121) + ' Progress: ' + CAST(@totalCount AS NVARCHAR(10)) + ' processed so far...';

            FETCH NEXT FROM DU INTO @uid, @title, @date;
        END

        CLOSE DU;
        DEALLOCATE DU;

        PRINT 'Decline pass complete. Total: ' + CAST(@totalCount AS NVARCHAR(10))
            + ' | Succeeded: ' + CAST(@successCount AS NVARCHAR(10))
            + ' | Failed: ' + CAST(@errorCount AS NVARCHAR(10))
            + CASE @testRun WHEN 1 THEN ' (TEST RUN — nothing was actually declined)' ELSE '' END;

        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = CASE WHEN @errorCount = 0 THEN 'Success' ELSE 'CompletedWithErrors' END,
            RowsAffected = @successCount,
            Detail = 'Total=' + CAST(@totalCount AS NVARCHAR(10)) + ', Succeeded=' + CAST(@successCount AS NVARCHAR(10))
                   + ', Failed=' + CAST(@errorCount AS NVARCHAR(10)) + ', TestRun=' + CAST(@testRun AS NVARCHAR(1))
        WHERE StepId = @LogId;
    END TRY
    BEGIN CATCH
        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Failed', Detail = ERROR_MESSAGE()
        WHERE StepId = @LogId;
        PRINT 'FATAL ERROR in DeclineSupersededUpdates: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc, EndTimeUtc, Status, Detail)
    VALUES ('DeclineSupersededUpdates', SYSUTCDATETIME(), SYSUTCDATETIME(), 'Skipped', 'Disabled via SESSION_CONTEXT');
    PRINT 'DeclineSupersededUpdates skipped (disabled).';
END
GO


/* =============================================================================
   SECTION 6 — FULL INDEX REBUILD (OPTIONAL, OFF BY DEFAULT — HEAVY)
   =============================================================================
   Replaces sp_MSforeachtable with a documented, catalog-driven equivalent
   (loop over sys.tables). Only run this if Section 2's targeted reindex was
   insufficient, or SUSDB has never had maintenance performed and is severely
   degraded. This can run for a long time on a large SUSDB and will hold
   locks per table during the rebuild (offline rebuild unless Enterprise
   Edition + ONLINE=ON, which most WSUS/WID deployments don't have).
   ============================================================================= */
IF CAST(SESSION_CONTEXT(N'Susdb_EnableFullRebuild') AS BIT) = 1
   AND ISNULL(CAST(SESSION_CONTEXT(N'Susdb_ConfirmFullRebuild') AS BIT), 0) = 1
BEGIN
    DECLARE @StepStart DATETIME2(3) = SYSUTCDATETIME();
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc) VALUES ('FullRebuild', @StepStart);
    DECLARE @LogId INT = SCOPE_IDENTITY();  -- v2: captured immediately

    PRINT 'NOTE: Full rebuild is offline on Standard/Express/WID and will block concurrent access table-by-table for its duration. Run during a maintenance window.';

    BEGIN TRY
        DECLARE @FillFactor INT = CAST(SESSION_CONTEXT(N'Susdb_RebuildFillFactor') AS INT);
        DECLARE @MaxDop INT = CAST(SESSION_CONTEXT(N'Susdb_RebuildMaxDop') AS INT); -- NULL = server default
        DECLARE @tblSchema NVARCHAR(128), @tblName NVARCHAR(128), @rebuildSql NVARCHAR(600);
        DECLARE @RebuiltTables INT = 0, @FailedTables INT = 0;

        DECLARE curTables CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
            SELECT s.name, t.name
            FROM sys.tables t
            INNER JOIN sys.schemas s ON t.schema_id = s.schema_id;

        OPEN curTables;
        FETCH NEXT FROM curTables INTO @tblSchema, @tblName;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @rebuildSql = N'ALTER INDEX ALL ON ' + QUOTENAME(@tblSchema) + N'.' + QUOTENAME(@tblName)
                    + N' REBUILD WITH (FILLFACTOR = ' + CAST(@FillFactor AS NVARCHAR(10))
                    + CASE WHEN @MaxDop IS NOT NULL THEN N', MAXDOP = ' + CAST(@MaxDop AS NVARCHAR(3)) ELSE N'' END + N');';
                EXEC (@rebuildSql);
                SET @RebuiltTables += 1;
                PRINT CONVERT(NVARCHAR, GETDATE(), 121) + ' Rebuilt all indexes on ' + @tblSchema + N'.' + @tblName;
            END TRY
            BEGIN CATCH
                SET @FailedTables += 1;
                INSERT INTO #ErrorDetail (StepName, ItemKey, ErrorMessage)
                VALUES ('FullRebuild', @tblSchema + N'.' + @tblName, ERROR_MESSAGE());
                PRINT 'ERROR rebuilding indexes on ' + @tblSchema + N'.' + @tblName + ': ' + ERROR_MESSAGE();
            END CATCH
            FETCH NEXT FROM curTables INTO @tblSchema, @tblName;
        END

        CLOSE curTables;
        DEALLOCATE curTables;

        PRINT 'Full rebuild complete. Tables rebuilt: ' + CAST(@RebuiltTables AS NVARCHAR(10)) + ' | Failed: ' + CAST(@FailedTables AS NVARCHAR(10));
        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = CASE WHEN @FailedTables = 0 THEN 'Success' ELSE 'CompletedWithErrors' END,
            RowsAffected = @RebuiltTables, Detail = 'Rebuilt=' + CAST(@RebuiltTables AS NVARCHAR(10)) + ', Failed=' + CAST(@FailedTables AS NVARCHAR(10))
        WHERE StepId = @LogId;
    END TRY
    BEGIN CATCH
        UPDATE #MaintenanceLog SET EndTimeUtc = SYSUTCDATETIME(), Status = 'Failed', Detail = ERROR_MESSAGE()
        WHERE StepId = @LogId;
        PRINT 'FATAL ERROR in FullRebuild: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
BEGIN
    INSERT INTO #MaintenanceLog (StepName, StartTimeUtc, EndTimeUtc, Status, Detail)
    VALUES ('FullRebuild', SYSUTCDATETIME(), SYSUTCDATETIME(), 'Skipped',
        'Requires BOTH Susdb_EnableFullRebuild = 1 AND Susdb_ConfirmFullRebuild = 1 (two-flag opt-in by design)');
    PRINT 'FullRebuild skipped (requires both Susdb_EnableFullRebuild = 1 and Susdb_ConfirmFullRebuild = 1).';
END
GO


/* =============================================================================
   SECTION 7 — RUN SUMMARY
   =============================================================================
   Final report: one row per step, with duration and outcome. Query this
   after the run for the article / change record.
   ============================================================================= */
SELECT
    StepName,
    Status,
    RowsAffected,
    DATEDIFF(SECOND, StartTimeUtc, EndTimeUtc)                         AS DurationSeconds,
    Detail
FROM #MaintenanceLog
ORDER BY StepId;

SELECT
    'TOTAL RUN DURATION (seconds)' AS Metric,
    DATEDIFF(SECOND, MIN(StartTimeUtc), MAX(EndTimeUtc)) AS Value
FROM #MaintenanceLog;

-- v2: individual failures (specific index/table/UpdateID + error message),
-- persisted beyond the PRINT output — the record a DBA actually needs when
-- following up on a "CompletedWithErrors" status above.
SELECT StepName, ItemKey, ErrorMessage, ErrorTimeUtc
FROM #ErrorDetail
ORDER BY ErrorId;
GO

-- END OF SCRIPT (v2)
