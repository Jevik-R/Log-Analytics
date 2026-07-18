USE log_ingestor_v2;

-- Proof 1: filtering by Server_ID only touches that server's partition.
-- Look at the `partitions` column in the output -- it should list only
-- p_server_2, not all three.
EXPLAIN
SELECT * FROM Application_Logs WHERE Server_ID = 2;

-- Proof 2: same, with an aggregate query (the kind we actually run).
EXPLAIN
SELECT COUNT(*), AVG(Status_Code) FROM Application_Logs WHERE Server_ID = 3;

-- Proof 3: a query with NO Server_ID filter touches all partitions
-- (expected -- shown for contrast, this is what "no pruning" looks like).
EXPLAIN
SELECT COUNT(*) FROM Application_Logs;
 
