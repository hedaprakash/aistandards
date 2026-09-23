-- File-level I/O latency statistics
-- Shows read/write latency per database file to identify storage bottlenecks
-- Latency guidelines: <10ms Good, 10-20ms OK, 20-50ms Concerning, >50ms Problem

SELECT
    DB_NAME(vfs.database_id) AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.type_desc AS FileType,
    mf.physical_name AS PhysicalPath,
    vfs.num_of_reads AS TotalReads,
    vfs.num_of_writes AS TotalWrites,
    CASE WHEN vfs.num_of_reads = 0 THEN 0
         ELSE (vfs.io_stall_read_ms / vfs.num_of_reads)
    END AS AvgReadLatencyMS,
    CASE WHEN vfs.num_of_writes = 0 THEN 0
         ELSE (vfs.io_stall_write_ms / vfs.num_of_writes)
    END AS AvgWriteLatencyMS,
    CASE WHEN (vfs.num_of_reads + vfs.num_of_writes) = 0 THEN 0
         ELSE (vfs.io_stall / (vfs.num_of_reads + vfs.num_of_writes))
    END AS AvgOverallLatencyMS,
    vfs.io_stall_read_ms AS TotalReadStallMS,
    vfs.io_stall_write_ms AS TotalWriteStallMS,
    CAST(vfs.size_on_disk_bytes / 1024.0 / 1024.0 AS DECIMAL(10,2)) AS FileSizeMB
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
    ON vfs.database_id = mf.database_id
    AND vfs.file_id = mf.file_id
ORDER BY
    CASE WHEN vfs.num_of_writes = 0 THEN 0
         ELSE (vfs.io_stall_write_ms / vfs.num_of_writes)
    END DESC;
