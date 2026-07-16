USE log_ingestor_v2;

SET GLOBAL event_scheduler = ON;

DELIMITER $$

-- ---------------------------------------------------------------------
-- Procedure: refresh_hourly_rollup
-- MySQL has no native materialized view. This procedure IS the
-- "materialized view" pattern: it recomputes the aggregate and
-- rewrites a real table, so read-path dashboards query a tiny
-- pre-aggregated table instead of scanning raw Application_Logs.
-- ---------------------------------------------------------------------
CREATE PROCEDURE refresh_hourly_rollup()
BEGIN
    REPLACE INTO Hourly_Traffic_Rollup (Server_ID, Hour_Bucket, Request_Count, Error_Count)
    SELECT
        Server_ID,
        DATE_FORMAT(App_Timestamp, '%Y-%m-%d %H:00:00') AS Hour_Bucket,
        COUNT(*) AS Request_Count,
        SUM(CASE WHEN Status_Code >= 400 THEN 1 ELSE 0 END) AS Error_Count
    FROM Application_Logs
    GROUP BY Server_ID, DATE_FORMAT(App_Timestamp, '%Y-%m-%d %H:00:00');
END$$

-- ---------------------------------------------------------------------
-- Procedure: detect_brute_force
-- Batch pattern-detection: >=3 suspicious/blocked hits from the same
-- IP within any single minute, on a sensitive endpoint. Writes
-- qualifying IPs into Alerts. This is the "periodic scan" counterpart
-- to the real-time single-row trigger above -- real systems use both.
-- ---------------------------------------------------------------------
CREATE PROCEDURE detect_brute_force()
BEGIN
    INSERT INTO Alerts (Server_ID, Alert_Type, Client_IP, Details)
    SELECT
        Server_ID,
        'BRUTE_FORCE',
        Client_IP,
        CONCAT('Detected ', attempt_count, ' suspicious attempts between ',
               first_attempt, ' and ', last_attempt)
    FROM (
        SELECT
            Server_ID,
            Client_IP,
            DATE_FORMAT(Sec_Timestamp, '%Y-%m-%d %H:%i:00') AS minute_bucket,
            COUNT(*) AS attempt_count,
            MIN(Sec_Timestamp) AS first_attempt,
            MAX(Sec_Timestamp) AS last_attempt
        FROM Security_Logs
        WHERE Security_Level IN ('Suspicious', 'Blocked')
          AND End_Point IN ('/login', '/admin')
        GROUP BY Server_ID, Client_IP, minute_bucket
        HAVING COUNT(*) >= 3
    ) AS candidates
    WHERE NOT EXISTS (
        SELECT 1 FROM Alerts a
        WHERE a.Server_ID = candidates.Server_ID
          AND a.Client_IP = candidates.Client_IP
          AND a.Alert_Type = 'BRUTE_FORCE'
          AND a.Details LIKE CONCAT('%', candidates.first_attempt, '%')
    );
END$$

-- ---------------------------------------------------------------------
-- Procedure: archive_old_sessions
-- Retention/archival: log data grows unboundedly in real systems, so
-- "keep everything forever" isn't a real design. This deletes session
-- rows (and cascades to their child metric/app/security/production
-- rows for that Log_ID) older than a cutoff date, per server.
--
-- NOTE: because InnoDB doesn't support FKs on partitioned tables,
-- there's no automatic ON DELETE CASCADE here -- child rows are
-- deleted explicitly in the correct order. This is a direct
-- consequence of the partitioning design decision and is called out
-- rather than hidden. A production system would more likely use
-- RANGE-partitioning on time for the archived tables specifically,
-- so old partitions could be dropped instantly instead of row-deleted
-- -- noted as a documented limitation/future improvement.
-- ---------------------------------------------------------------------
CREATE PROCEDURE archive_old_sessions(IN cutoff_date DATE)
BEGIN
    DECLARE done INT DEFAULT FALSE;
    DECLARE v_server_id INT;
    DECLARE v_log_id BIGINT;
    DECLARE cur CURSOR FOR
        SELECT Server_ID, Log_ID FROM Logs WHERE Startup < cutoff_date;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    DROP TEMPORARY TABLE IF EXISTS tmp_old_sessions;
    CREATE TEMPORARY TABLE tmp_old_sessions (Server_ID INT, Log_ID BIGINT);
    INSERT INTO tmp_old_sessions SELECT Server_ID, Log_ID FROM Logs WHERE Startup < cutoff_date;

    DELETE sm FROM Server_Metrics_Logs sm
        JOIN tmp_old_sessions t ON sm.Server_ID = t.Server_ID AND sm.Log_ID = t.Log_ID;
    DELETE al FROM Application_Logs al
        JOIN tmp_old_sessions t ON al.Server_ID = t.Server_ID AND al.Log_ID = t.Log_ID;
    DELETE sl FROM Security_Logs sl
        JOIN tmp_old_sessions t ON sl.Server_ID = t.Server_ID AND sl.Log_ID = t.Log_ID;
    DELETE pl FROM Production_Logs pl
        JOIN tmp_old_sessions t ON pl.Server_ID = t.Server_ID AND pl.Log_ID = t.Log_ID;
    DELETE l FROM Logs l
        JOIN tmp_old_sessions t ON l.Server_ID = t.Server_ID AND l.Log_ID = t.Log_ID;

    DROP TEMPORARY TABLE IF EXISTS tmp_old_sessions;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- Scheduled EVENTs: run the two procedures periodically, the way a
-- real system would (e.g. rollups refreshed hourly, brute-force scan
-- every few minutes). Interval shortened here for demo purposes.
-- ---------------------------------------------------------------------
CREATE EVENT IF NOT EXISTS ev_refresh_hourly_rollup
ON SCHEDULE EVERY 1 HOUR
DO CALL refresh_hourly_rollup();

CREATE EVENT IF NOT EXISTS ev_detect_brute_force
ON SCHEDULE EVERY 5 MINUTE
DO CALL detect_brute_force();
