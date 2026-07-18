# Log Analytics DB 

A redesign of an earlier DBMS coursework project ("Log-Ingestor"), rebuilt to
actually justify calling it a partitioned/sharded design, with generated
data, real system behavior (triggers, scheduled jobs, alerting), and
measured proof rather than assertions.


## Architecture

**Partition key: `Server_ID`, using MySQL `PARTITION BY LIST`.**
Chosen because the dominant access pattern here is "give me this server's
data" (health checks, per-server cost, per-server traffic) — not
time-range scans across all servers. A `RANGE` partition on timestamp
would suit that different access pattern instead; it wasn't the right
choice here and I'm not claiming it would have been.

```
Cluster_Table (unpartitioned, small, rarely written)
Event_Type_Lookup (unpartitioned reference data)
Logs                 -- PARTITION BY LIST(Server_ID): p_server_1/2/3
Server_Metrics_Logs  -- same
Application_Logs     -- same
Security_Logs        -- same
Production_Logs      -- same
Alerts                (unpartitioned -- alert volume is orders of
                        magnitude smaller than raw logs)
Hourly_Traffic_Rollup  (unpartitioned -- manual "materialized view")
```



## What's actually in this repo

| File | What it does |
|---|---|
| `sql/01_schema.sql` | Partitioned schema, all design decisions commented inline |
| `sql/02_reference_data.sql` | Cluster + event-type lookup seed data |
| `sql/03_triggers.sql` | Real-time triggers (last-seen tracking, instant security alerts) |
| `sql/04_events_and_procedures.sql` | Scheduled rollup refresh, batch brute-force detection, retention procedure |
| `sql/05_optimized_queries.sql` | All 14 original queries, rewritten — no `UNION ALL` needed anymore |
| `sql/06_partition_pruning_proof.sql` | `EXPLAIN` / `EXPLAIN ANALYZE` proving pruning actually happens |
| `scripts/generate_data.py` | Simulated traffic generator — diurnal patterns, injected anomalies with known ground truth |
| `proof/` | Captured, real command output for everything below |


## How to reproduce

```bash
mysql < sql/01_schema.sql
mysql < sql/02_reference_data.sql
mysql < sql/03_triggers.sql
mysql < sql/04_events_and_procedures.sql
python3 scripts/generate_data.py
mysql log_ingestor_v2 -e "CALL refresh_hourly_rollup(); CALL detect_brute_force();"
mysql log_ingestor_v2 < sql/05_optimized_queries.sql
mysql log_ingestor_v2 < sql/06_partition_pruning_proof.sql
```

## Team / attribution

DBMS coursework (ERD, normalization, initial query set) team project (IT214, DA-IICT). 
