-- I/O statistics summarized by drive letter
-- Aggregates all database files per drive to identify drive-level storage bottlenecks
-- Shows total reads/writes, latency, and file count per drive
-- Latency guidelines: <10ms Good, 10-20ms OK, 20-50ms Concerning, >50ms Problem

SELECT
    LEFT(mf.physical_name, 1) AS DriveLetter,
    COUNT(DISTINCT mf.database_id) AS DatabaseCount,
    COUNT(*) AS FileCount,
    SUM(CASE WHEN mf.type_desc = 'LOG' THEN 1 ELSE 0 END) AS LogFileCount,
    SUM(CASE WHEN mf.type_desc = 'ROWS' THEN 1 ELSE 0 END) AS DataFileCount,
    SUM(vfs.num_of_reads) AS TotalReads,
    SUM(vfs.num_of_writes) AS TotalWrites,
    CAST(SUM(vfs.num_of_bytes_read) / 1024.0 / 1024.0 / 1024.0 AS DECIMAL(10,2)) AS TotalReadGB,
    CAST(SUM(vfs.num_of_bytes_written) / 1024.0 / 1024.0 / 1024.0 AS DECIMAL(10,2)) AS TotalWriteGB,
    CASE WHEN SUM(vfs.num_of_reads) = 0 THEN 0
         ELSE CAST(SUM(vfs.io_stall_read_ms) * 1.0 / SUM(vfs.num_of_reads) AS DECIMAL(10,2))
    END AS AvgReadLatencyMS,
    CASE WHEN SUM(vfs.num_of_writes) = 0 THEN 0
         ELSE CAST(SUM(vfs.io_stall_write_ms) * 1.0 / SUM(vfs.num_of_writes) AS DECIMAL(10,2))
    END AS AvgWriteLatencyMS,
    CASE WHEN (SUM(vfs.num_of_reads) + SUM(vfs.num_of_writes)) = 0 THEN 0
         ELSE CAST(SUM(vfs.io_stall) * 1.0 / (SUM(vfs.num_of_reads) + SUM(vfs.num_of_writes)) AS DECIMAL(10,2))
    END AS AvgOverallLatencyMS,
    CAST(SUM(vfs.size_on_disk_bytes) / 1024.0 / 1024.0 / 1024.0 AS DECIMAL(10,2)) AS TotalSizeGB
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
    AND vfs.file_id = mf.file_id
GROUP BY LEFT(mf.physical_name, 1)
ORDER BY AvgOverallLatencyMS DESC;
