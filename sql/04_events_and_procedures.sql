USE log_ingestor_v2;

SET GLOBAL event_scheduler = ON;

DELIMITER $$

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


DELIMITER ;


CREATE EVENT IF NOT EXISTS ev_refresh_hourly_rollup
ON SCHEDULE EVERY 1 HOUR
DO CALL refresh_hourly_rollup();

CREATE EVENT IF NOT EXISTS ev_detect_brute_force
ON SCHEDULE EVERY 5 MINUTE
DO CALL detect_brute_force();
