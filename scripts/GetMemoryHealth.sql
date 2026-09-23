-- GetMemoryHealth.sql
-- Memory health snapshot: PLE, actual usage, buffer pool stats
-- Key metrics for quick memory health assessment

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT
    -- Configuration (from sys.configurations for quick access)
    (SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations WHERE name = 'min server memory (MB)') AS MinServerMemoryMB,
    (SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations WHERE name = 'max server memory (MB)') AS MaxServerMemoryMB,

    -- Physical memory on server
    (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info) AS PhysicalMemoryMB,

    -- Current memory usage
    (SELECT cntr_value / 1024 FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Total Server Memory (KB)') AS TotalServerMemoryMB,

    -- Target memory (what SQL Server wants)
    (SELECT cntr_value / 1024 FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Target Server Memory (KB)') AS TargetServerMemoryMB,

    -- Page Life Expectancy (key health metric - higher is better, <300 is concerning)
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Page life expectancy') AS PageLifeExpectancy,

    -- Memory grants pending (should be 0, >0 indicates memory pressure)
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Memory Grants Pending') AS MemoryGrantsPending,

    -- Buffer cache hit ratio (should be >99% for OLTP)
    (SELECT CAST(
        (SELECT cntr_value FROM sys.dm_os_performance_counters
         WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Buffer cache hit ratio') * 100.0 /
        NULLIF((SELECT cntr_value FROM sys.dm_os_performance_counters
         WHERE object_name LIKE '%Buffer Manager%' AND counter_name = 'Buffer cache hit ratio base'), 0)
     AS DECIMAL(5,2))) AS BufferCacheHitRatioPct,

    -- Database cache memory
    (SELECT cntr_value / 1024 FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Database Cache Memory (KB)') AS DatabaseCacheMemoryMB,

    -- Free memory
    (SELECT cntr_value / 1024 FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Free Memory (KB)') AS FreeMemoryMB,

    -- Stolen server memory (used for purposes other than buffer pool)
    (SELECT cntr_value / 1024 FROM sys.dm_os_performance_counters
     WHERE object_name LIKE '%Memory Manager%' AND counter_name = 'Stolen Server Memory (KB)') AS StolenServerMemoryMB;
