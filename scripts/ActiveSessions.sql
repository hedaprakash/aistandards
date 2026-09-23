-- ActiveSessions.sql
-- Shows active sessions with blocking, waits, queries, and resource usage
-- Simplified from quickTroubleshooting.sql for QQE health check
-- No temp tables or cursors - single batch execution

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT
    s.session_id,
    r.blocking_session_id AS blocked_by,
    DB_NAME(r.database_id) AS database_name,
    s.host_name,
    s.program_name,
    s.login_name,
    s.status AS session_status,
    r.command,
    r.wait_type,
    r.wait_resource,
    r.wait_time / 1000 AS wait_time_sec,
    r.cpu_time / 1000 AS cpu_time_sec,
    r.total_elapsed_time / 1000 AS elapsed_time_sec,
    r.reads + r.writes AS physical_io,
    r.granted_query_memory * 8 / 1024 AS granted_memory_mb,
    r.percent_complete,
    CASE r.transaction_isolation_level
        WHEN 0 THEN 'Unspecified'
        WHEN 1 THEN 'ReadUncommitted'
        WHEN 2 THEN 'ReadCommitted'
        WHEN 3 THEN 'Repeatable'
        WHEN 4 THEN 'Serializable'
        WHEN 5 THEN 'Snapshot'
    END AS isolation_level,
    r.open_transaction_count,
    r.start_time AS request_start_time,
    DATEDIFF(SECOND, r.start_time, GETDATE()) AS running_seconds,
    SUBSTRING(
        qt.text,
        (r.statement_start_offset / 2) + 1,
        CASE
            WHEN r.statement_end_offset = -1 OR r.statement_end_offset = 0
            THEN DATALENGTH(qt.text)
            ELSE r.statement_end_offset
        END - r.statement_start_offset / 2 + 1
    ) AS current_statement,
    qt.text AS full_query_text
FROM sys.dm_exec_sessions s
INNER JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS qt
WHERE s.session_id > 50  -- Exclude system sessions
  AND s.session_id <> @@SPID  -- Exclude this session
ORDER BY
    CASE WHEN r.blocking_session_id > 0 THEN 0 ELSE 1 END,  -- Blocked sessions first
    r.cpu_time DESC;
