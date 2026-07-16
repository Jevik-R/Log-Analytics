USE log_ingestor_v2;

-- =====================================================================
-- Every query below replaces an equivalent from the original project.
-- The original design forced a 3-way UNION ALL across Server_ID_1/2/3
-- tables in ~half the queries. With Server_ID as a normal filter/group
-- column on partitioned tables, that UNION ALL disappears entirely --
-- MySQL's partition pruning does the "only look at the relevant
-- server's data" work that the UNION ALL was manually doing before.
-- =====================================================================

-- 1) Server health classification (was: hardcoded to Server_ID_1_Server_Logs only)
--    Now works for ANY server via a parameter, no per-server query needed.
SELECT
    Metric_Timestamp,
    Disk_Space_Usage_MB,
    Memory_Space_Usage_MB,
    CPU_Utilization_Pct,
    Temperature_C,
    CASE
        WHEN Disk_Space_Usage_MB < 700000 AND Memory_Space_Usage_MB < 1200000
             AND CPU_Utilization_Pct < 60 AND Temperature_C < 80 THEN 'Good'
        WHEN Disk_Space_Usage_MB < 900000 AND Memory_Space_Usage_MB < 1700000
             AND CPU_Utilization_Pct < 85 AND Temperature_C < 85 THEN 'Moderate'
        ELSE 'Bad'
    END AS server_health_status
FROM Server_Metrics_Logs
WHERE Server_ID = 1;                       -- <- partition pruning kicks in here

-- 2) Peak-hour traffic analysis (was: hardcoded Server 2 only)
WITH HourlyTraffic AS (
    SELECT HOUR(App_Timestamp) AS hour_of_day, COUNT(*) AS total_requests
    FROM Application_Logs
    WHERE Server_ID = 2
    GROUP BY HOUR(App_Timestamp)
)
SELECT
    hour_of_day, total_requests,
    CASE
        WHEN hour_of_day BETWEEN 6 AND 11 THEN 'Morning'
        WHEN hour_of_day BETWEEN 12 AND 17 THEN 'Afternoon'
        WHEN hour_of_day BETWEEN 18 AND 23 THEN 'Evening'
        ELSE 'Night'
    END AS time_period,
    CASE
        WHEN total_requests >= (SELECT AVG(total_requests) + 2 * STDDEV(total_requests) FROM HourlyTraffic)
        THEN 'Peak' ELSE 'Normal'
    END AS traffic_status
FROM HourlyTraffic
ORDER BY total_requests DESC;

-- 3) Crash detection across ALL servers (was: 3-way UNION ALL, one per server table)
SELECT Server_ID, Prod_Timestamp, Message
FROM Production_Logs
WHERE Message LIKE '%failure%' OR Message LIKE '%crash%' OR Message LIKE '%error%'
   OR Message LIKE '%Exception%'
ORDER BY Prod_Timestamp DESC;

-- 4) Total cost per server in a fixed window (was: 3-way UNION ALL + join)
SELECT
    c.Server_ID, c.IP_Address, c.Location,
    SUM(l.Cost) AS total_cost,
    COUNT(*) AS total_sessions,
    MIN(l.Startup) AS first_session,
    MAX(l.Shutdown) AS last_session
FROM Logs l
JOIN Cluster_Table c ON l.Server_ID = c.Server_ID
WHERE l.Startup BETWEEN '2025-03-01 00:00:00' AND '2025-03-31 23:59:59'
GROUP BY c.Server_ID, c.IP_Address, c.Location
ORDER BY total_cost DESC;

-- 5) Brute-force detection across ALL servers at once (was: hardcoded to Server 2 only)
--    Now also uses the ENUM Security_Level instead of LIKE '%suspicious%' string matching.
SELECT
    Server_ID, Client_IP,
    COUNT(*) AS Attempt_Count,
    MIN(Sec_Timestamp) AS First_Attempt,
    MAX(Sec_Timestamp) AS Last_Attempt
FROM Security_Logs
WHERE Security_Level IN ('Suspicious', 'Blocked')
  AND End_Point IN ('/login', '/admin')
GROUP BY Server_ID, Client_IP, DATE_FORMAT(Sec_Timestamp, '%Y-%m-%d %H:%i')
HAVING COUNT(*) >= 3
ORDER BY Attempt_Count DESC;

-- 6) IPs hitting multiple servers within the same 1-hour window
--    (was: 3-way UNION ALL of Application_Logs per server; now one scan, one GROUP BY)
WITH IP_Access_Counts AS (
    SELECT
        Client_IP,
        DATE_FORMAT(App_Timestamp, '%Y-%m-%d %H:00:00') AS hour_window,
        COUNT(DISTINCT Server_ID) AS servers_accessed
    FROM Application_Logs
    GROUP BY Client_IP, hour_window
)
SELECT * FROM IP_Access_Counts WHERE servers_accessed >= 2 ORDER BY hour_window, Client_IP;

-- 7) Average uptime per server (was: 3-way UNION ALL subquery)
SELECT Server_ID, AVG(TIMESTAMPDIFF(SECOND, Startup, Shutdown) / 3600.0) AS Avg_Uptime_Hours
FROM Logs
WHERE Shutdown IS NOT NULL
GROUP BY Server_ID;

-- 8) Correlate application access with security events (was: hardcoded to Server 3)
SELECT
    al.Server_ID, al.Client_IP, al.End_Point, al.App_Timestamp,
    sl.Sec_Timestamp, sl.Security_Level, sl.Event_Type_ID
FROM Application_Logs al
JOIN Security_Logs sl
  ON al.Server_ID = sl.Server_ID
 AND al.Client_IP = sl.Client_IP
 AND sl.Sec_Timestamp BETWEEN al.App_Timestamp AND al.App_Timestamp + INTERVAL 600 SECOND
WHERE sl.Security_Level = 'High'
ORDER BY al.Server_ID, al.Client_IP, al.App_Timestamp;

-- 9) Avg resource usage per session, highest CPU sessions first (was: hardcoded Server 3)
SELECT
    Server_ID, Log_ID,
    COUNT(*) AS Entry_Count,
    ROUND(AVG(CPU_Utilization_Pct), 2) AS Avg_CPU,
    ROUND(AVG(Memory_Space_Usage_MB), 2) AS Avg_Memory,
    ROUND(AVG(Disk_Space_Usage_MB), 2) AS Avg_Disk
FROM Server_Metrics_Logs
GROUP BY Server_ID, Log_ID
ORDER BY Avg_CPU DESC;

-- 10) CPU/memory spike detection via self-join on 5-min sliding window
--     (was: hardcoded to Server 3 only; now works across all servers,
--     and partition pruning still applies if you add a Server_ID filter)
SELECT
    curr.Server_ID, curr.Log_ID,
    curr.Metric_Timestamp AS Reading_Time,
    prev.Metric_Timestamp AS Previous_Reading_Time,
    curr.CPU_Utilization_Pct - prev.CPU_Utilization_Pct AS CPU_Spike,
    curr.Memory_Space_Usage_MB - prev.Memory_Space_Usage_MB AS Mem_Jump
FROM Server_Metrics_Logs curr
JOIN Server_Metrics_Logs prev
  ON curr.Server_ID = prev.Server_ID
 AND curr.Log_ID = prev.Log_ID
 AND curr.Metric_Timestamp > prev.Metric_Timestamp
 AND curr.Metric_Timestamp <= prev.Metric_Timestamp + INTERVAL 5 MINUTE
WHERE (curr.CPU_Utilization_Pct - prev.CPU_Utilization_Pct > 15)
   OR (curr.Memory_Space_Usage_MB - prev.Memory_Space_Usage_MB > 500)
ORDER BY curr.Server_ID, curr.Log_ID, curr.Metric_Timestamp;

-- 11) All 4xx/5xx production errors across ALL servers (was: 3-way UNION ALL + join)
SELECT pl.Server_ID, pl.Prod_Timestamp, pl.Status_Code, pl.Message, pl.Developer_ID, pl.Process_ID
FROM Production_Logs pl
WHERE pl.Status_Code BETWEEN 400 AND 599
ORDER BY pl.Prod_Timestamp DESC;

-- 12) Frequent restarts (>2/day), any server (was: hardcoded to Server 3)
SELECT Server_ID, DATE(Startup) AS Restart_Date, COUNT(*) AS Restart_Count
FROM Logs
GROUP BY Server_ID, DATE(Startup)
HAVING COUNT(*) > 2
ORDER BY Restart_Count DESC;

-- 13) Most frequently accessed endpoints, any server (was: hardcoded to Server 1)
SELECT Server_ID, End_Point, COUNT(*) AS Hit_Count
FROM Application_Logs
GROUP BY Server_ID, End_Point
ORDER BY Server_ID, Hit_Count DESC;

-- 14) Developers with most production errors, any server (was: hardcoded to Server 1)
SELECT Server_ID, Developer_ID, COUNT(*) AS Error_Count
FROM Production_Logs
WHERE Status_Code BETWEEN 400 AND 599
GROUP BY Server_ID, Developer_ID
ORDER BY Server_ID, Error_Count DESC;
