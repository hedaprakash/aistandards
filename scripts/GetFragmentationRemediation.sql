-- GetFragmentationRemediation.sql
-- Generates ready-to-run remediation SQL script for fragmented indexes
-- Reads from tempdb.dbo.FragmentationResults (populated by GetFragmentationLowBlocking.sql)
-- Stores output into tempdb.dbo.FragmentationRemediation for clean reporting
-- Output: Single column (RemediationScript) with full SQL commands + comments + GO statements
-- Can be copied directly into SSMS and executed

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

-- Verify collection table exists (must run GetFragmentationLowBlocking.sql first)
IF OBJECT_ID('tempdb.dbo.FragmentationResults') IS NULL
BEGIN
    RAISERROR('tempdb.dbo.FragmentationResults does not exist. Run GetFragmentationLowBlocking.sql first.', 16, 1);
    RETURN;
END

-- Check SQL Server edition for ONLINE rebuild support
DECLARE @SupportsOnlineRebuild BIT = 0;
IF SERVERPROPERTY('EngineEdition') = 3 -- Enterprise
    SET @SupportsOnlineRebuild = 1;

DECLARE @TotalIndexes INT = (SELECT COUNT(*) FROM tempdb.dbo.FragmentationResults);

-- =============================================
-- Store remediation script into permanent table
-- =============================================
IF OBJECT_ID('tempdb.dbo.FragmentationRemediation') IS NOT NULL DROP TABLE tempdb.dbo.FragmentationRemediation;
CREATE TABLE tempdb.dbo.FragmentationRemediation (
    SortOrder INT,
    RemediationScript VARCHAR(MAX)
);

-- Script Header
INSERT INTO tempdb.dbo.FragmentationRemediation (SortOrder, RemediationScript)
SELECT 0,
    '-- =============================================' + CHAR(13) + CHAR(10) +
    '-- Index Remediation Script' + CHAR(13) + CHAR(10) +
    '-- Server: ' + @@SERVERNAME + CHAR(13) + CHAR(10) +
    '-- Generated: ' + CONVERT(VARCHAR(20), GETDATE(), 120) + CHAR(13) + CHAR(10) +
    '-- Total Indexes: ' + CAST(@TotalIndexes AS VARCHAR(10)) + CHAR(13) + CHAR(10) +
    '-- =============================================' + CHAR(13) + CHAR(10) +
    'SET NOCOUNT ON;' + CHAR(13) + CHAR(10) +
    'GO';

-- Individual Index Commands
INSERT INTO tempdb.dbo.FragmentationRemediation (SortOrder, RemediationScript)
SELECT
    Rowidnum,
    -- For READ_ONLY databases: Add SET READ_WRITE before first index
    CASE WHEN flgUpdateability = 1 THEN
        CHAR(13) + CHAR(10) +
        '-- *** DATABASE [' + DatabaseName + '] IS READ_ONLY - Setting to READ_WRITE ***' + CHAR(13) + CHAR(10) +
        'ALTER DATABASE [' + DatabaseName + '] SET READ_WRITE WITH NO_WAIT;' + CHAR(13) + CHAR(10) +
        'GO' + CHAR(13) + CHAR(10)
    ELSE '' END +
    -- Comment block with context
    CHAR(13) + CHAR(10) +
    '-- Index: [' + IndexName + '] on [' + DatabaseName + '].[' + SchemaName + '].[' + TableName + ']' + CHAR(13) + CHAR(10) +
    '-- Fragmentation: ' + CAST(CAST(AvgFragmentation AS INT) AS VARCHAR(10)) + '%, ' +
    'Pages: ' + FORMAT(PageCount, 'N0') + ', ' +
    'Rows: ' + FORMAT(TotalRows, 'N0') + CHAR(13) + CHAR(10) +
    '-- Action: ' + RecommendedAction + ', ' +
    'Mode: ' + CASE WHEN CanRebuildOnline = 1 THEN 'ONLINE' ELSE 'OFFLINE' END +
    CASE WHEN CanRebuildOnline = 0 THEN ' (has LOB/XML columns)' ELSE '' END + CHAR(13) + CHAR(10) +
    'PRINT ''[' + CAST(Rowidnum AS VARCHAR(10)) + '/' + CAST(@TotalIndexes AS VARCHAR(10)) + '] ' +
    RecommendedAction + ': [' + IndexName + '] on [' + DatabaseName + '].[' + SchemaName + '].[' + TableName + '] (' +
    CAST(CAST(AvgFragmentation AS INT) AS VARCHAR(10)) + '%, ' + FORMAT(PageCount, 'N0') + ' pages)'';' + CHAR(13) + CHAR(10) +
    -- The ALTER INDEX statement
    CASE RecommendedAction
        WHEN 'REORGANIZE' THEN
            'ALTER INDEX [' + IndexName + '] ON [' + DatabaseName + '].[' + SchemaName + '].[' + TableName + '] REORGANIZE;'
        WHEN 'REBUILD' THEN
            'ALTER INDEX [' + IndexName + '] ON [' + DatabaseName + '].[' + SchemaName + '].[' + TableName + '] REBUILD WITH (' +
            'FILLFACTOR = ' + CAST(ExpectedFillFactor AS VARCHAR(3)) + ', ' +
            'SORT_IN_TEMPDB = ON, STATISTICS_NORECOMPUTE = OFF, ' +
            'ONLINE = ' + CASE WHEN @SupportsOnlineRebuild = 1 AND CanRebuildOnline = 1 THEN 'ON' ELSE 'OFF' END + ');'
        ELSE ''
    END + CHAR(13) + CHAR(10) +
    'GO' +
    -- For READ_ONLY databases: Add SET READ_ONLY after last index
    CASE WHEN flgUpdateability = 2 THEN
        CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10) +
        '-- *** Restoring DATABASE [' + DatabaseName + '] to READ_ONLY ***' + CHAR(13) + CHAR(10) +
        'ALTER DATABASE [' + DatabaseName + '] SET READ_ONLY WITH NO_WAIT;' + CHAR(13) + CHAR(10) +
        'GO'
    ELSE '' END
FROM tempdb.dbo.FragmentationResults
ORDER BY Rowidnum;

-- =============================================
-- RESULT SET: Simple read from permanent table
-- =============================================
SELECT RemediationScript
FROM tempdb.dbo.FragmentationRemediation
ORDER BY SortOrder;
