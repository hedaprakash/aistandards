-- GetFragmentationLowBlocking.sql
-- Low-blocking fragmentation collection using per-database scanning
-- Uses LIMITED mode, pre-filtering, and yields between databases
-- Includes: Online rebuild detection, fill factor logic, AG-awareness, remediation SQL
-- Collects all >10% into temp table, then stores >20% into permanent tempdb table for reporting

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

-- Working temp table for collection (all >10% fragmentation)
IF OBJECT_ID('tempdb..#FragmentationResults') IS NOT NULL DROP TABLE #FragmentationResults;
CREATE TABLE #FragmentationResults (
    DatabaseName VARCHAR(200),
    SchemaName VARCHAR(200),
    TableName VARCHAR(200),
    IndexName VARCHAR(500),
    IndexId INT,
    IndexTypeDesc VARCHAR(50),
    AvgFragmentation DECIMAL(5,1),
    PageCount BIGINT,
    TotalRows BIGINT,
    [FillFactor] INT,
    ExpectedFillFactor INT,
    FragmentCount BIGINT,
    AvgFragmentSizePages DECIMAL(10,2),
    ObjectId INT,
    DatabaseId INT,
    CanRebuildOnline BIT DEFAULT 1,
    RecommendedAction VARCHAR(20),
    RemediationSQL VARCHAR(2000),
    Updateability VARCHAR(200),       -- READ_WRITE or READ_ONLY
    flgUpdateability INT DEFAULT 0    -- 0=normal, 1=first in READ_ONLY db (set to READ_WRITE), 2=last in READ_ONLY db (set back to READ_ONLY)
);

-- Temp table for LOB columns (tables requiring OFFLINE rebuild)
IF OBJECT_ID('tempdb..#OfflineOnlyTables') IS NOT NULL DROP TABLE #OfflineOnlyTables;
CREATE TABLE #OfflineOnlyTables (
    DatabaseId INT,
    ObjectId INT
);

-- Check SQL Server edition for ONLINE rebuild support
DECLARE @SupportsOnlineRebuild BIT = 0;
IF SERVERPROPERTY('EngineEdition') = 3 -- Enterprise
    SET @SupportsOnlineRebuild = 1;

-- Database cursor - ordered by size (smallest first for faster lock release)
DECLARE @DbName NVARCHAR(200), @DbId INT;
DECLARE @SQL NVARCHAR(MAX);

-- Track database updateability status
DECLARE @DbUpdateability VARCHAR(200);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
SELECT d.name, d.database_id, CAST(DATABASEPROPERTYEX(d.name, 'Updateability') AS VARCHAR(200))
FROM sys.databases d
WHERE d.state_desc = 'ONLINE'
  AND d.name NOT IN ('master', 'model', 'tempdb', 'msdb')
  -- Include both READ_WRITE and READ_ONLY databases
  -- Skip AG secondaries (if AG exists)
  AND NOT EXISTS (
      SELECT 1 FROM sys.dm_hadr_database_replica_states drs
      WHERE drs.database_id = d.database_id
        AND drs.is_primary_replica = 0
  )
ORDER BY (SELECT ISNULL(SUM(size), 0) FROM sys.master_files mf WHERE mf.database_id = d.database_id);

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName, @DbId, @DbUpdateability;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- Collect fragmentation for this database using LIMITED mode
    INSERT INTO #FragmentationResults (
        DatabaseName, SchemaName, TableName, IndexName, IndexId, IndexTypeDesc,
        AvgFragmentation, PageCount, FragmentCount, AvgFragmentSizePages,
        ObjectId, DatabaseId, Updateability
    )
    SELECT
        DB_NAME(ps.database_id),
        OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id),
        OBJECT_NAME(ps.object_id, ps.database_id),
        NULL, -- Will be enriched later
        ps.index_id,
        ps.index_type_desc,
        CAST(ps.avg_fragmentation_in_percent AS DECIMAL(5,1)),
        ps.page_count,
        ps.fragment_count,
        ps.avg_fragment_size_in_pages,
        ps.object_id,
        ps.database_id,
        @DbUpdateability
    FROM sys.dm_db_index_physical_stats(@DbId, NULL, NULL, NULL, 'LIMITED') ps
    WHERE ps.avg_fragmentation_in_percent > 10  -- Only fragmented indexes
      AND ps.page_count > 500                    -- Only sizeable indexes
      AND ps.index_type_desc <> 'HEAP'           -- Skip heaps
      AND ps.alloc_unit_type_desc = 'IN_ROW_DATA'; -- Skip LOB allocation units

    -- Collect tables with LOB/XML columns for this database (require OFFLINE rebuild)
    SET @SQL = N'
    INSERT INTO #OfflineOnlyTables (DatabaseId, ObjectId)
    SELECT DISTINCT ' + CAST(@DbId AS NVARCHAR(10)) + N', c.object_id
    FROM [' + @DbName + N'].sys.columns c
    WHERE c.system_type_id IN (34, 35, 99, 241)  -- image, text, ntext, xml
       OR c.max_length = -1;                       -- varchar(max), nvarchar(max), varbinary(max)
    ';
    EXEC sp_executesql @SQL;

    -- Yield point - allow other operations to proceed
    WAITFOR DELAY '00:00:00.050';

    FETCH NEXT FROM db_cursor INTO @DbName, @DbId, @DbUpdateability;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-- Mark tables that cannot be rebuilt online
UPDATE fr SET CanRebuildOnline = 0
FROM #FragmentationResults fr
JOIN #OfflineOnlyTables ot ON fr.DatabaseId = ot.DatabaseId AND fr.ObjectId = ot.ObjectId;

-- Enrich with index metadata (index name, fill factor, row count)
-- Using dynamic SQL to query each database's sys.indexes
DECLARE enrich_cursor CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
SELECT DISTINCT DatabaseId, DatabaseName FROM #FragmentationResults;

OPEN enrich_cursor;
FETCH NEXT FROM enrich_cursor INTO @DbId, @DbName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL = N'
    UPDATE fr SET
        IndexName = i.name,
        [FillFactor] = i.fill_factor,
        ExpectedFillFactor = ISNULL(NULLIF(i.fill_factor, 0), 90),
        TotalRows = ISNULL(ps.row_count, 0)
    FROM #FragmentationResults fr
    JOIN [' + @DbName + N'].sys.indexes i
        ON fr.ObjectId = i.object_id AND fr.IndexId = i.index_id
    LEFT JOIN [' + @DbName + N'].sys.dm_db_partition_stats ps
        ON fr.ObjectId = ps.object_id AND fr.IndexId = ps.index_id
    WHERE fr.DatabaseId = ' + CAST(@DbId AS NVARCHAR(10)) + N';
    ';
    EXEC sp_executesql @SQL;

    FETCH NEXT FROM enrich_cursor INTO @DbId, @DbName;
END

CLOSE enrich_cursor;
DEALLOCATE enrich_cursor;

-- Set recommended action based on fragmentation level
UPDATE #FragmentationResults SET
    RecommendedAction = CASE
        WHEN AvgFragmentation BETWEEN 10 AND 30 AND PageCount >= 1000 THEN 'REORGANIZE'
        WHEN AvgFragmentation > 30 THEN 'REBUILD'
        WHEN AvgFragmentation BETWEEN 10 AND 30 AND PageCount < 1000 THEN 'REBUILD'
        ELSE 'NONE'
    END;

-- Generate remediation SQL
UPDATE #FragmentationResults SET
    RemediationSQL = CASE RecommendedAction
        WHEN 'REORGANIZE' THEN
            'ALTER INDEX [' + IndexName + '] ON [' + DatabaseName + '].[' + SchemaName + '].[' + TableName + '] REORGANIZE;'
        WHEN 'REBUILD' THEN
            'ALTER INDEX [' + IndexName + '] ON [' + DatabaseName + '].[' + SchemaName + '].[' + TableName + '] REBUILD WITH (' +
            'FILLFACTOR = ' + CAST(ExpectedFillFactor AS VARCHAR(3)) + ', ' +
            'SORT_IN_TEMPDB = ON, ' +
            'ONLINE = ' + CASE WHEN @SupportsOnlineRebuild = 1 AND CanRebuildOnline = 1 THEN 'ON' ELSE 'OFF' END + ');'
        ELSE ''
    END
WHERE RecommendedAction IN ('REORGANIZE', 'REBUILD');

-- =============================================
-- Store >20% results into permanent tempdb table
-- =============================================
IF OBJECT_ID('tempdb.dbo.FragmentationResults') IS NOT NULL DROP TABLE tempdb.dbo.FragmentationResults;

SELECT
    fr.DatabaseName, fr.SchemaName, fr.TableName, fr.IndexName, fr.IndexId, fr.IndexTypeDesc,
    fr.AvgFragmentation, fr.PageCount, fr.TotalRows, fr.[FillFactor], fr.ExpectedFillFactor,
    fr.FragmentCount, fr.AvgFragmentSizePages, fr.ObjectId, fr.DatabaseId,
    fr.CanRebuildOnline, fr.RecommendedAction, fr.RemediationSQL, fr.Updateability,
    ISNULL(us.user_seeks, 0) AS UserSeeks,
    ISNULL(us.user_scans, 0) AS UserScans,
    ISNULL(us.user_lookups, 0) AS UserLookups,
    ISNULL(us.user_updates, 0) AS UserUpdates,
    (SELECT MAX(dt) FROM (VALUES (us.last_user_seek), (us.last_user_scan), (us.last_user_lookup)) AS T(dt)) AS LastRead,
    CAST(0 AS INT) AS flgUpdateability,
    CAST(ROW_NUMBER() OVER (ORDER BY (fr.AvgFragmentation * fr.PageCount) DESC, fr.DatabaseName, fr.TableName) AS INT) AS Rowidnum,
    CAST(60 + CEILING(fr.PageCount / 10000.0) AS INT) AS TimeoutValue,
    CAST(0 AS BIGINT) AS SubtotalPages,
    CAST(0 AS BIT) AS flgBackupLog
INTO tempdb.dbo.FragmentationResults
FROM #FragmentationResults fr
LEFT JOIN sys.dm_db_index_usage_stats us
    ON fr.DatabaseId = us.database_id
    AND fr.ObjectId = us.object_id
    AND fr.IndexId = us.index_id
WHERE fr.AvgFragmentation > 20;

-- Calculate running total of pages for log backup scheduling
;WITH RunningTotal AS (
    SELECT Rowidnum,
           SUM(PageCount) OVER (ORDER BY Rowidnum ROWS UNBOUNDED PRECEDING) AS RunningPages
    FROM tempdb.dbo.FragmentationResults
)
UPDATE fr SET SubtotalPages = rt.RunningPages
FROM tempdb.dbo.FragmentationResults fr
JOIN RunningTotal rt ON fr.Rowidnum = rt.Rowidnum;

-- Flag rows where log backup should run (every ~2M pages processed)
UPDATE a SET flgBackupLog = 1
FROM tempdb.dbo.FragmentationResults a
WHERE Rowidnum IN (
    SELECT MAX(Rowidnum) AS LogBackupID
    FROM tempdb.dbo.FragmentationResults
    GROUP BY SubtotalPages / 2000000
);

-- Flag first index in each READ_ONLY database (need to set to READ_WRITE before reindexing)
UPDATE a SET flgUpdateability = 1
FROM tempdb.dbo.FragmentationResults a
JOIN (
    SELECT DatabaseName, MIN(Rowidnum) AS MinRowidnum
    FROM tempdb.dbo.FragmentationResults
    WHERE Updateability = 'READ_ONLY'
    GROUP BY DatabaseName
) b ON a.DatabaseName = b.DatabaseName AND a.Rowidnum = b.MinRowidnum;

-- Flag last index in each READ_ONLY database (need to set back to READ_ONLY after reindexing)
UPDATE a SET flgUpdateability = 2
FROM tempdb.dbo.FragmentationResults a
JOIN (
    SELECT DatabaseName, MAX(Rowidnum) AS MaxRowidnum
    FROM tempdb.dbo.FragmentationResults
    WHERE Updateability = 'READ_ONLY'
    GROUP BY DatabaseName
) b ON a.DatabaseName = b.DatabaseName AND a.Rowidnum = b.MaxRowidnum;

-- Detect log backup job name
DECLARE @LogBackupJob VARCHAR(500) = NULL;
IF EXISTS (SELECT name FROM msdb..sysjobs WHERE name IN ('DBA:Backup All Tlogs', 'DBA_BackupDB.LogBackup') AND enabled = 1)
    SELECT @LogBackupJob = 'EXEC msdb..sp_start_job @job_name = ''' + name + ''''
    FROM msdb..sysjobs
    WHERE name IN ('DBA:Backup All Tlogs', 'DBA_BackupDB.LogBackup') AND enabled = 1;

-- =============================================
-- RESULT SET: Simple read from permanent table
-- (Uses EXEC to defer column resolution until after SELECT INTO creates the table)
-- =============================================
EXEC('
SELECT
    DatabaseName,
    SchemaName,
    TableName,
    IndexName,
    IndexTypeDesc AS IndexType,
    AvgFragmentation AS FragPct,
    PageCount,
    TotalRows,
    [FillFactor] AS CurrentFF,
    ExpectedFillFactor AS TargetFF,
    FragmentCount AS Fragments,
    CAST(AvgFragmentSizePages AS INT) AS AvgFragSize,
    CASE WHEN CanRebuildOnline = 1 THEN ''Yes'' ELSE ''No'' END AS CanOnline,
    RecommendedAction AS Action,
    UserSeeks,
    UserScans,
    UserLookups,
    UserUpdates,
    CONVERT(VARCHAR(16), LastRead, 120) AS LastRead
FROM tempdb.dbo.FragmentationResults
ORDER BY Rowidnum;
');

-- Cleanup working tables (permanent table intentionally persists for remediation script)
DROP TABLE #FragmentationResults;
DROP TABLE #OfflineOnlyTables;
