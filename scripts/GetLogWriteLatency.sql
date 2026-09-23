-- Log file write latency per database
-- Identifies databases with slow transaction log writes (potential storage bottleneck)
-- Filters to databases with at least 10,000 log writes for meaningful stats
-- Latency guidelines: <2ms Excellent, 2-5ms Good, 5-10ms OK, >10ms Concerning

SELECT
    DB_NAME(vfs.database_id) AS DatabaseName,
    SUM(vfs.num_of_writes) AS TotalLogWrites,
    SUM(vfs.io_stall_write_ms) AS TotalLogStallMS,
    CAST(
        SUM(vfs.io_stall_write_ms) * 1.0 /
        NULLIF(SUM(vfs.num_of_writes), 0)
        AS DECIMAL(10,3)
    ) AS AvgMsPerLogWrite
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf
    ON vfs.database_id = mf.database_id
   AND vfs.file_id = mf.file_id
WHERE mf.type_desc = 'LOG'
GROUP BY vfs.database_id
HAVING SUM(vfs.num_of_writes) >= 10000
ORDER BY AvgMsPerLogWrite DESC;
