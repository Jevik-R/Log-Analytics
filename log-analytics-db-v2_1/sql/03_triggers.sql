USE log_ingestor_v2;

DELIMITER $$

-- Trigger 1: keep Cluster_Table.Last_Seen fresh whenever a server
-- starts a new session. Demonstrates a trigger crossing from a
-- partitioned table into an unpartitioned reference table.
CREATE TRIGGER trg_logs_update_last_seen
AFTER INSERT ON Logs
FOR EACH ROW
BEGIN
    UPDATE Cluster_Table
    SET Last_Seen = NEW.Startup
    WHERE Server_ID = NEW.Server_ID
      AND (Last_Seen IS NULL OR Last_Seen < NEW.Startup);
END$$

-- Trigger 2: real-time alerting. Any security event logged as
-- 'Blocked' or 'Suspicious' is immediately surfaced into Alerts,
-- instead of only being discoverable by someone running a SELECT
-- later. Batch/pattern-based detection (brute force over a time
-- window) is handled separately by the scheduled EVENT in
-- 04_events.sql, since that requires aggregating multiple rows,
-- not just reacting to one.
CREATE TRIGGER trg_security_realtime_alert
AFTER INSERT ON Security_Logs
FOR EACH ROW
BEGIN
    IF NEW.Security_Level IN ('Blocked', 'Suspicious') THEN
        INSERT INTO Alerts (Server_ID, Alert_Type, Client_IP, Details)
        VALUES (
            NEW.Server_ID,
            'SECURITY_BLOCK',
            NEW.Client_IP,
            CONCAT('Security level ', NEW.Security_Level, ' on endpoint ', NEW.End_Point,
                   ' at ', NEW.Sec_Timestamp)
        );
    END IF;
END$$

DELIMITER ;
