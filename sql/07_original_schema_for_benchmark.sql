-- This recreates the ORIGINAL design's Application_Logs pattern
-- (one hardcoded table per server, no indexes) so it can be benchmarked
-- against the new partitioned+indexed design on identical data volume.
USE log_ingestor_v1_original;

CREATE TABLE Server_ID_1_Application_Logs (
    TimestampAL1 TIMESTAMP,
    Client_IP_AddressAL1 VARCHAR(255) NOT NULL,
    HTTP_Method VARCHAR(10) NOT NULL,
    Event_TypeAL1 INT NOT NULL,
    End_PointAL1 VARCHAR(255) NOT NULL,
    Status_CodeAL1 INT NOT NULL
);

CREATE TABLE Server_ID_2_Application_Logs (
    TimestampAL2 TIMESTAMP,
    Client_IP_AddressAL2 VARCHAR(255) NOT NULL,
    HTTP_Method VARCHAR(10) NOT NULL,
    Event_TypeAL2 INT NOT NULL,
    End_PointAL2 VARCHAR(255) NOT NULL,
    Status_CodeAL2 INT NOT NULL
);

CREATE TABLE Server_ID_3_Application_Logs (
    TimestampAL3 TIMESTAMP,
    Client_IP_AddressAL3 VARCHAR(255) NOT NULL,
    HTTP_Method VARCHAR(10) NOT NULL,
    Event_TypeAL3 INT NOT NULL,
    End_PointAL3 VARCHAR(255) NOT NULL,
    Status_CodeAL3 INT NOT NULL
);
