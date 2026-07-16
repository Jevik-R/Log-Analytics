# Log Analytics DB — Sharded/Partitioned Redesign (v2)

A redesign of an earlier DBMS coursework project ("Log-Ingestor"), rebuilt to
actually justify calling it a partitioned/sharded design, with generated
data, real system behavior (triggers, scheduled jobs, alerting), and
measured proof rather than assertions.

## Why this redesign exists

The original project modeled three servers as three hand-written, duplicated
sets of tables (`Server_ID_1_Logs`, `Server_ID_2_Logs`, `Server_ID_3_Logs`,
...). Every cross-server query needed a manual 3-way `UNION ALL`. Adding a
4th server meant writing new DDL and editing every query by hand. The
README called this "scalable" and "sharded" — it wasn't; it was schema
duplication. This version fixes that, and also addresses two other gaps:
all data was hand-typed `INSERT` statements (no simulation of real traffic),
and the project only ever did read-only ad hoc `SELECT`s — no triggers, no
scheduled jobs, no derived/alerting state.

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

## Design decisions and their trade-offs (stated up front, not hidden)

1. **No global `AUTO_INCREMENT` across partitions.** MySQL requires every
   unique key on a partitioned table to include the partition column, so a
   single centralized auto-increment can't provide global uniqueness here.
   This is a real, known distributed-systems problem — it's the same
   reason real sharded systems use UUIDs, Snowflake IDs, or per-shard
   counters instead of one global sequence. IDs here are generated
   per-`Server_ID` from the application layer (`generate_data.py`), which
   is sufficient for the `(Server_ID, ID)` composite primary keys used
   throughout.

2. **No enforced foreign keys from the partitioned log tables back to
   `Cluster_Table`.** InnoDB does not support foreign keys on partitioned
   tables at all. `Cluster_Table` stays unpartitioned, but referential
   integrity from `Logs.Server_ID → Cluster_Table.Server_ID` is enforced
   at the application layer, not by the database engine. This is a real
   limitation of the chosen design, not an oversight — worth being able
   to say out loud in an interview rather than have someone else find it.

3. **No native materialized views in MySQL.** `Hourly_Traffic_Rollup` is a
   plain table, kept fresh by a scheduled `EVENT` that calls
   `refresh_hourly_rollup()` and rewrites it from raw `Application_Logs`.
   This is the manual equivalent of what Postgres's `MATERIALIZED VIEW
   ... REFRESH` gives natively — stated explicitly so it's clear this is
   a deliberate workaround, not a misunderstanding of MySQL's features.

4. **Retention/archival deletes rows rather than dropping partitions.**
   Because the partition key is `Server_ID` (not time), old data can't be
   discarded by simply dropping a time-based partition — `archive_old_sessions()`
   does an explicit cascading `DELETE` instead. A production system
   optimizing specifically for retention would likely sub-partition by
   time as well (`PARTITION BY LIST ... SUBPARTITION BY RANGE`) so old
   data could be dropped instantly. Noted here as a real limitation and
   a documented direction for further work, not implemented in this pass.

## What's actually in this repo

| File | What it does |
|---|---|
| `sql/01_schema.sql` | Partitioned schema, all design decisions commented inline |
| `sql/02_reference_data.sql` | Cluster + event-type lookup seed data |
| `sql/03_triggers.sql` | Real-time triggers (last-seen tracking, instant security alerts) |
| `sql/04_events_and_procedures.sql` | Scheduled rollup refresh, batch brute-force detection, retention procedure |
| `sql/05_optimized_queries.sql` | All 14 original queries, rewritten — no `UNION ALL` needed anymore |
| `sql/06_partition_pruning_proof.sql` | `EXPLAIN` / `EXPLAIN ANALYZE` proving pruning actually happens |
| `sql/07_original_schema_for_benchmark.sql` | Recreates the *original* design for a fair side-by-side benchmark |
| `scripts/generate_data.py` | Simulated traffic generator — diurnal patterns, injected anomalies with known ground truth |
| `proof/` | Captured, real command output for everything below |

## Evidence, not assertions

**1. Partitioning actually prunes.** From `proof/partition_pruning.txt`:

```
EXPLAIN SELECT * FROM Application_Logs WHERE Server_ID = 2;
  -> partitions: p_server_2                (only one partition touched)

EXPLAIN SELECT COUNT(*) FROM Application_Logs;     -- no filter, shown for contrast
  -> partitions: p_server_1,p_server_2,p_server_3  (all three, as expected)
```

**2. Adding a server is now 2 statements + zero query changes**, verified
in `proof/add_server_4_demo.txt` — `INSERT` into `Cluster_Table` +
`ALTER TABLE ... ADD PARTITION`, five times (one per log table). Every
query in `05_optimized_queries.sql` picks up server 4's data automatically,
with no edits, once data exists for it. The original design needed 5 new
`CREATE TABLE` statements and hand-edits to the `UNION ALL` chain in 7 of
the 14 queries.

**3. Measured performance difference** (`proof/timing_benchmark.txt`,
~34,000 `Application_Logs` rows, identical data in both schemas):

| Query | Original (no index, per-server table) | New (partitioned + indexed) |
|---|---|---|
| Single-server filtered count | 6.0ms avg | 3.2ms avg (~1.9x) |
| Cross-server aggregate | 29.6ms avg | 24.3ms avg (~1.2x) |

Honest caveat: at this data volume the gap is real but not dramatic — a
34k-row full scan is still fast in absolute terms. The gap widens
substantially as data grows (a full scan is O(n) per query; a pruned,
indexed lookup is not), and I'd expect a much larger difference at
millions of rows. The bigger, unconditional win here isn't raw speed at
this scale — it's that the cross-server query no longer needs a hand-maintained
`UNION ALL`, and correctness doesn't depend on remembering to edit N query
blocks every time a server is added.

**4. Brute-force detection verified against ground truth**, not just "it
ran without errors." `generate_data.py` injects a known number of
brute-force bursts (specific IP, specific time window) and logs them to
`proof/ground_truth.json`. Running `detect_brute_force()` and diffing its
output against that ground truth:

```
Injected:  27 brute-force bursts
Detected:  27
Missed (false negatives): 0
Extra (false positives):  0
```

**5. Triggers demonstrably work without manual intervention** — after
running the data generator, `Cluster_Table.Last_Seen` reflects the most
recent session start time for each server, purely from the
`trg_logs_update_last_seen` trigger firing on every `Logs` insert. No
code updates it directly.

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

## What I'd still call out as unfinished, if asked

- True distributed sharding (separate physical database nodes, a routing
  layer, cross-shard transactions) is a different and harder problem.
  MySQL's `PARTITION BY LIST` here is single-node logical partitioning —
  it improves query planning and manageability, but everything still
  lives on one MySQL instance. I'm not claiming this is a distributed
  database.
- Retention is row-delete based, not partition-drop based (see decision
  #4 above) — a real gap if this needed to run at genuine scale.
- Foreign key integrity from log tables to `Cluster_Table` is
  application-enforced, not database-enforced (see decision #2).

## Team / attribution

Original DBMS coursework (ERD, normalization, initial query set) was a
3-person team project (IT214, DA-IICT). This redesign — partitioning,
triggers, scheduled events, alerting, data generation, and the
partition-pruning/benchmark proof — was done individually as a follow-up
to make the project resume-appropriate for SDE interviews.
