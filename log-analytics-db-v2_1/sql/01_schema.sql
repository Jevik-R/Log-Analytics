-- =====================================================================
-- Log Analytics DB — v2 Schema
-- Redesign of the original "Log-Ingestor" DBMS project.
--
-- KEY DESIGN DECISIONS (documented inline, referenced in README):
--
-- 1. PARTITION KEY = Server_ID (LIST partitioning).
--    Chosen because the dominant query pattern in this system filters
--    or aggregates by an individual server (health checks, per-server
--    cost, per-server traffic), not by time range. A RANGE partition
--    on timestamp would suit a "give me last month across all servers"
--    workload instead — that's not our access pattern here.
--
-- 2. NO GLOBAL AUTO_INCREMENT ACROSS PARTITIONS.
--    MySQL requires every unique key on a partitioned table to include
--    the partitioning column. An AUTO_INCREMENT column can't safely
--    provide global cross-partition uniqueness under that constraint.
--    This is a genuine, well-known distributed-systems problem (the
--    same reason real sharded systems use UUIDs, Snowflake IDs, or
--    per-shard counters instead of a single centralized auto-increment).
--    We generate IDs from the application layer (see generate_data.py)
--    rather than pretending MySQL solves this for us.
--
-- 3. FOREIGN KEYS TO Cluster_Table ARE NOT ENFORCED AT THE DB LEVEL.
--    InnoDB does not support foreign keys on partitioned tables.
--    Cluster_Table stays unpartitioned (small, rarely written), but
--    the reference from Logs/Application_Logs/etc. -> Cluster_Table
--    is enforced at the application layer (generate_data.py validates
--    Server_ID against Cluster_Table before insert). This is called
--    out explicitly rather than hidden, because "why isn't this a
--    real FK?" is exactly the kind of question this design invites.
-- =====================================================================

DROP DATABASE IF EXISTS log_ingestor_v2;
CREATE DATABASE log_ingestor_v2;
USE log_ingestor_v2;

-- ---------------------------------------------------------------------
-- Unpartitioned reference/lookup tables
-- ---------------------------------------------------------------------

CREATE TABLE Cluster_Table (
    Server_ID   INT PRIMARY KEY,
    IP_Address  VARCHAR(45) NOT NULL UNIQUE,
    Log_Format  VARCHAR(50) NOT NULL,
    Location    VARCHAR(100) NOT NULL,
    Last_Seen   TIMESTAMP NULL      -- populated by trigger, see 03_triggers.sql
);

CREATE TABLE Event_Type_Lookup (
    Event_Type_ID   INT PRIMARY KEY,
    Event_Name      VARCHAR(100) NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- Core session table: one row per server startup/shutdown session.
-- Partitioned by LIST(Server_ID) — replaces Server_ID_1_Logs /
-- Server_ID_2_Logs / Server_ID_3_Logs from the original design.
-- ---------------------------------------------------------------------

CREATE TABLE Logs (
    Server_ID   INT NOT NULL,
    Log_ID      BIGINT NOT NULL,           -- app-generated, unique per Server_ID
    Startup     DATETIME NOT NULL,
    Shutdown    DATETIME NULL,
    Cost        DECIMAL(15,2) NULL CHECK (Cost >= 0),
    PRIMARY KEY (Server_ID, Log_ID),
    INDEX idx_logs_startup (Server_ID, Startup)
) PARTITION BY LIST (Server_ID) (
    PARTITION p_server_1 VALUES IN (1),
    PARTITION p_server_2 VALUES IN (2),
    PARTITION p_server_3 VALUES IN (3)
);

-- ---------------------------------------------------------------------
-- Server resource-usage metrics. Replaces Server_ID_N_Server_Logs.
-- Numeric types used throughout instead of VARCHAR('45 %') — the
-- original schema stored percentages/temperatures as strings, forcing
-- every downstream query to REPLACE(...)::numeric. That's fixed here.
-- ---------------------------------------------------------------------

CREATE TABLE Server_Metrics_Logs (
    Server_ID           INT NOT NULL,
    Metric_ID           BIGINT NOT NULL,
    Log_ID              BIGINT NOT NULL,        -- which session this metric belongs to
    Metric_Timestamp    DATETIME NOT NULL,
    Temperature_C       DECIMAL(5,2) NOT NULL CHECK (Temperature_C BETWEEN -50 AND 150),
    Disk_Space_Usage_MB BIGINT NOT NULL CHECK (Disk_Space_Usage_MB >= 0),
    Memory_Space_Usage_MB BIGINT NOT NULL CHECK (Memory_Space_Usage_MB >= 0),
    CPU_Utilization_Pct DECIMAL(5,2) NOT NULL CHECK (CPU_Utilization_Pct BETWEEN 0 AND 100),
    PRIMARY KEY (Server_ID, Metric_ID),
    INDEX idx_metrics_ts (Server_ID, Metric_Timestamp),
    INDEX idx_metrics_logid (Server_ID, Log_ID)
) PARTITION BY LIST (Server_ID) (
    PARTITION p_server_1 VALUES IN (1),
    PARTITION p_server_2 VALUES IN (2),
    PARTITION p_server_3 VALUES IN (3)
);

-- ---------------------------------------------------------------------
-- Application (HTTP) logs. Replaces Server_ID_N_Application_Logs.
-- Event_Type is now a proper FK-style lookup instead of a bare INT.
-- ---------------------------------------------------------------------

CREATE TABLE Application_Logs (
    Server_ID       INT NOT NULL,
    App_Log_ID      BIGINT NOT NULL,
    Log_ID          BIGINT NOT NULL,
    App_Timestamp   DATETIME NOT NULL,
    Client_IP       VARCHAR(45) NOT NULL,
    HTTP_Method     VARCHAR(10) NOT NULL,
    Event_Type_ID   INT NOT NULL,
    End_Point       VARCHAR(255) NOT NULL,
    Status_Code     SMALLINT NOT NULL CHECK (Status_Code BETWEEN 100 AND 599),
    PRIMARY KEY (Server_ID, App_Log_ID),
    INDEX idx_app_ip_ts (Server_ID, Client_IP, App_Timestamp),
    INDEX idx_app_ts (Server_ID, App_Timestamp),
    INDEX idx_app_status (Server_ID, Status_Code)
) PARTITION BY LIST (Server_ID) (
    PARTITION p_server_1 VALUES IN (1),
    PARTITION p_server_2 VALUES IN (2),
    PARTITION p_server_3 VALUES IN (3)
);

-- ---------------------------------------------------------------------
-- Security logs. Replaces Server_ID_N_Security_Logs.
-- Security_Level is now a controlled ENUM instead of free-text
-- matched with LIKE '%suspicious%'.
-- ---------------------------------------------------------------------

CREATE TABLE Security_Logs (
    Server_ID       INT NOT NULL,
    Sec_Log_ID      BIGINT NOT NULL,
    Log_ID          BIGINT NOT NULL,
    Sec_Timestamp   DATETIME NOT NULL,
    Client_IP       VARCHAR(45) NOT NULL,
    Security_Level  ENUM('Low','Medium','High','Suspicious','Blocked') NOT NULL,
    Event_Type_ID   INT NOT NULL,
    End_Point       VARCHAR(255) NOT NULL,
    PRIMARY KEY (Server_ID, Sec_Log_ID),
    INDEX idx_sec_ip_ts (Server_ID, Client_IP, Sec_Timestamp),
    INDEX idx_sec_level (Server_ID, Security_Level)
) PARTITION BY LIST (Server_ID) (
    PARTITION p_server_1 VALUES IN (1),
    PARTITION p_server_2 VALUES IN (2),
    PARTITION p_server_3 VALUES IN (3)
);

-- ---------------------------------------------------------------------
-- Production/error logs. Replaces Server_ID_N_Production_Logs.
-- ---------------------------------------------------------------------

CREATE TABLE Production_Logs (
    Server_ID       INT NOT NULL,
    Prod_Log_ID     BIGINT NOT NULL,
    Log_ID          BIGINT NOT NULL,
    Prod_Timestamp  DATETIME NOT NULL,
    Developer_ID    INT NOT NULL,
    Process_ID      INT NOT NULL,
    Status_Code     SMALLINT NOT NULL CHECK (Status_Code BETWEEN 100 AND 599),
    Message         VARCHAR(500) NOT NULL,
    PRIMARY KEY (Server_ID, Prod_Log_ID),
    INDEX idx_prod_ts (Server_ID, Prod_Timestamp),
    INDEX idx_prod_status (Server_ID, Status_Code),
    INDEX idx_prod_dev (Server_ID, Developer_ID)
) PARTITION BY LIST (Server_ID) (
    PARTITION p_server_1 VALUES IN (1),
    PARTITION p_server_2 VALUES IN (2),
    PARTITION p_server_3 VALUES IN (3)
);

-- ---------------------------------------------------------------------
-- Alerts — derived/system state, not just an ad hoc query result.
-- Populated by trigger (real-time) and by a scheduled EVENT that
-- re-runs the brute-force detection pattern periodically (batch).
-- Unpartitioned: alert volume is orders of magnitude smaller than logs.
-- ---------------------------------------------------------------------

CREATE TABLE Alerts (
    Alert_ID        BIGINT AUTO_INCREMENT PRIMARY KEY,
    Server_ID       INT NOT NULL,
    Alert_Type      VARCHAR(50) NOT NULL,      -- e.g. 'BRUTE_FORCE', 'SECURITY_BLOCK'
    Client_IP       VARCHAR(45) NULL,
    Detected_At     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    Details         VARCHAR(500) NOT NULL,
    INDEX idx_alerts_server (Server_ID),
    INDEX idx_alerts_type (Alert_Type)
);

-- ---------------------------------------------------------------------
-- Hourly traffic rollup — MySQL has no native materialized view, so
-- this table + the refresh EVENT in 04_events.sql is the manual
-- equivalent: a real table, periodically repopulated from raw logs,
-- so dashboards read a small pre-aggregated table instead of
-- recomputing from millions of raw Application_Logs rows every time.
-- ---------------------------------------------------------------------

CREATE TABLE Hourly_Traffic_Rollup (
    Server_ID       INT NOT NULL,
    Hour_Bucket     DATETIME NOT NULL,
    Request_Count   INT NOT NULL,
    Error_Count     INT NOT NULL,
    Last_Refreshed  TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (Server_ID, Hour_Bucket)
);
