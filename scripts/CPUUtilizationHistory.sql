-- CPUUtilizationHistory.sql
-- Shows CPU utilization history from SQL Server ring buffer
-- Displays SQL Server CPU %, System Idle %, and Other Process CPU %
-- Adapted from CPUUtilization.sql for QQE health check

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ts_now BIGINT;
SELECT @ts_now = cpu_ticks / (cpu_ticks / ms_ticks) FROM sys.dm_os_sys_info;

SELECT TOP 30
    record_id,
    DATEADD(ms, -1 * (@ts_now - [timestamp]), GETDATE()) AS EventTime,
    SQLProcessUtilization AS SQL_CPU_Percent,
    SystemIdle AS System_Idle_Percent,
    100 - SystemIdle - SQLProcessUtilization AS Other_Process_CPU_Percent
FROM (
    SELECT
        record.value('(./Record/@id)[1]', 'int') AS record_id,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') AS SystemIdle,
        record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization,
        [timestamp]
    FROM (
        SELECT
            [timestamp],
            CONVERT(XML, record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE '%<SystemHealth>%'
    ) AS x
) AS y
ORDER BY record_id DESC;
