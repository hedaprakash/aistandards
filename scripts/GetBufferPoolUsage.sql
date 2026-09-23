-- SQL Server Memory Summary
-- Fast replacement for dm_os_buffer_descriptors scan (which times out on large buffer pools)
-- Uses performance counters (compatible with all SQL Server versions)

SELECT
    counter_name AS Metric,
    CAST(cntr_value / 1024 AS INT) AS Value_MB,
    'Memory Manager' AS Detail
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Memory Manager%'
AND counter_name IN (
    'Total Server Memory (KB)',
    'Target Server Memory (KB)',
    'Database Cache Memory (KB)',
    'Free Memory (KB)',
    'Stolen Server Memory (KB)',
    'Lock Memory (KB)',
    'SQL Cache Memory (KB)',
    'Optimizer Memory (KB)',
    'Granted Workspace Memory (KB)',
    'Connection Memory (KB)',
    'Log Pool Memory (KB)'
)
UNION ALL
SELECT
    'MaxServerMemory_MB',
    CAST(value_in_use AS INT),
    'Configuration'
FROM sys.configurations WHERE name = 'max server memory (MB)'
UNION ALL
SELECT
    'MinServerMemory_MB',
    CAST(value_in_use AS INT),
    'Configuration'
FROM sys.configurations WHERE name = 'min server memory (MB)'
UNION ALL
SELECT
    'SQLProcessMemory_MB',
    CAST(physical_memory_in_use_kb / 1024 AS INT),
    'Process Memory'
FROM sys.dm_os_process_memory;
