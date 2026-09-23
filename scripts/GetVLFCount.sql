-- Virtual Log File (VLF) count per database
-- High VLF counts can impact log performance and recovery time
-- Status: <=50 OK, 51-200 Monitor, 201-1000 HIGH, >1000 CRITICAL

SELECT
    db.name AS DatabaseName,
    COUNT(li.database_id) AS VLFCount,
    CAST(SUM(li.vlf_size_mb) AS DECIMAL(10,2)) AS TotalLogSizeMB,
    CASE
        WHEN COUNT(li.database_id) <= 50 THEN 'OK'
        WHEN COUNT(li.database_id) BETWEEN 51 AND 200 THEN 'Monitor'
        WHEN COUNT(li.database_id) BETWEEN 201 AND 1000 THEN 'HIGH'
        ELSE 'CRITICAL'
    END AS Status
FROM sys.databases db
CROSS APPLY sys.dm_db_log_info(db.database_id) li
WHERE db.state = 0
GROUP BY db.name, db.database_id
ORDER BY VLFCount DESC;
