"""
generate_data.py

Simulates realistic multi-server log traffic instead of hand-written
INSERT statements. This directly addresses the "no real-life touch,
everything manual" gap in the original project.

Simulated behavior (chosen to mirror how a real log/observability
system actually behaves, not arbitrary randomness):

  - Diurnal traffic: request volume follows a day/night curve per
    server, not a flat random rate.
  - Session structure: each server has multiple startup/shutdown
    sessions per day; all child rows (metrics, app logs, security
    logs, production logs) are attached to a real session (Log_ID),
    not generated independently.
  - Injected anomalies with ground truth: a known number of brute-force
    bursts, CPU/memory spikes, and production error clusters are
    injected at known times/IPs, so the later "detection" queries and
    procedures can be verified against a known answer -- this is what
    makes the benchmark/proof step meaningful rather than cosmetic.
  - Per-server monotonic IDs: matches the (Server_ID, ID) composite
    primary keys used by the partitioned schema (see 01_schema.sql
    for why a single global AUTO_INCREMENT wasn't used).
"""

import random
import datetime as dt
import mysql.connector

random.seed(42)  # reproducible runs

DB_CONFIG = dict(host="127.0.0.1", user="appuser", password="apppass", database="log_ingestor_v2")

SERVERS = [1, 2, 3]
SIM_DAYS = 45
SIM_START = dt.datetime(2025, 3, 1, 0, 0, 0)

END_POINTS = ["/home", "/login", "/admin", "/api/users", "/api/orders",
              "/api/payments", "/search", "/logout", "/dashboard", "/settings"]
SENSITIVE_ENDPOINTS = ["/login", "/admin"]
HTTP_METHODS = ["GET", "POST", "PUT", "DELETE"]
EVENT_TYPE_IDS = [1, 2, 3, 4, 5, 6, 7, 8]

ERROR_MESSAGES = [
    "NullPointerException in OrderService", "Database connection timeout",
    "Unhandled exception in payment gateway", "System crash: out of memory",
    "Failed to acquire lock on resource", "Segmentation fault in worker process",
]
INFO_MESSAGES = [
    "Request processed successfully", "Cache refreshed", "Scheduled job completed",
    "Health check passed", "Config reloaded",
]


def diurnal_weight(hour: int) -> float:
    """Traffic multiplier by hour-of-day: low at night, peak in afternoon."""
    return 0.15 + 0.85 * max(0.0, (1 - abs(hour - 14) / 12))


def gen_sessions(server_id: int):
    """Generate startup/shutdown sessions for one server across the sim window."""
    sessions = []
    log_id = 1
    current = SIM_START
    end_time = SIM_START + dt.timedelta(days=SIM_DAYS)
    while current < end_time:
        gap_hours = random.uniform(0.5, 4)
        startup = current + dt.timedelta(hours=gap_hours)
        duration_hours = random.uniform(1, 6)
        shutdown = startup + dt.timedelta(hours=duration_hours)
        cost = round(duration_hours * random.uniform(8, 14), 2)
        sessions.append((server_id, log_id, startup, shutdown, cost))
        log_id += 1
        current = shutdown
    return sessions


def gen_metrics_for_session(server_id, log_id, startup, shutdown, metric_id_start,
                             inject_spike_at=None):
    """Metrics every ~10 min during a session; optional injected spike."""
    rows = []
    mid = metric_id_start
    t = startup
    base_cpu, base_mem, base_disk = random.uniform(20, 40), random.uniform(500000, 800000), random.uniform(300000, 900000)
    while t < shutdown:
        cpu = base_cpu + random.uniform(-5, 5)
        mem = base_mem + random.uniform(-20000, 20000)
        disk = base_disk + random.uniform(-5000, 5000)
        temp = 45 + cpu * 0.4 + random.uniform(-2, 2)

        if inject_spike_at and abs((t - inject_spike_at).total_seconds()) < 300:
            cpu = min(99.9, cpu + 40)
            mem = mem + 600000  # >500MB jump, matches original spike-detection threshold

        rows.append((server_id, mid, log_id, t, round(temp, 2), int(disk),
                     int(mem), round(min(cpu, 100.0), 2)))
        mid += 1
        t += dt.timedelta(minutes=10)
    return rows, mid


def gen_app_logs_for_session(server_id, log_id, startup, shutdown, id_start):
    rows = []
    aid = id_start
    t = startup
    while t < shutdown:
        weight = diurnal_weight(t.hour)
        if random.random() < weight:
            status = random.choices([200, 201, 301, 404, 500, 503],
                                     weights=[70, 10, 5, 8, 5, 2])[0]
            rows.append((server_id, aid, log_id, t,
                         f"10.0.{server_id}.{random.randint(2,254)}",
                         random.choice(HTTP_METHODS),
                         random.choice(EVENT_TYPE_IDS),
                         random.choice(END_POINTS),
                         status))
            aid += 1
        t += dt.timedelta(minutes=random.uniform(1, 3))
    return rows, aid


def gen_security_logs_for_session(server_id, log_id, startup, shutdown, id_start,
                                   brute_force_ip=None, brute_force_at=None):
    rows = []
    sid = id_start
    t = startup
    while t < shutdown:
        if random.random() < 0.05:
            level = random.choices(["Low", "Medium", "High", "Suspicious", "Blocked"],
                                    weights=[50, 25, 15, 7, 3])[0]
            rows.append((server_id, sid, log_id, t,
                         f"10.0.{server_id}.{random.randint(2,254)}",
                         level, random.choice(EVENT_TYPE_IDS),
                         random.choice(END_POINTS)))
            sid += 1
        t += dt.timedelta(minutes=random.uniform(2, 10))

    # Injected brute-force burst: known IP, known window, >=3 hits/minute
    if brute_force_ip and brute_force_at and startup <= brute_force_at <= shutdown:
        for i in range(6):
            ts = brute_force_at + dt.timedelta(seconds=i * 8)
            rows.append((server_id, sid, log_id, ts, brute_force_ip,
                         "Suspicious", 4, "/login"))
            sid += 1
    return rows, sid


def gen_production_logs_for_session(server_id, log_id, startup, shutdown, id_start,
                                     inject_crash_at=None):
    rows = []
    pid = id_start
    t = startup
    while t < shutdown:
        if random.random() < 0.08:
            is_error = random.random() < 0.15
            status = random.choice([400, 404, 500, 502]) if is_error else random.choice([200, 201, 204])
            message = random.choice(ERROR_MESSAGES) if is_error else random.choice(INFO_MESSAGES)
            rows.append((server_id, pid, log_id, t, random.randint(1, 8),
                         random.randint(1000, 9999), status, message))
            pid += 1
        t += dt.timedelta(minutes=random.uniform(5, 20))

    if inject_crash_at and startup <= inject_crash_at <= shutdown:
        rows.append((server_id, pid, log_id, inject_crash_at, random.randint(1, 8),
                     random.randint(1000, 9999), 500, "System crash: out of memory"))
        pid += 1
    return rows, pid


def main():
    conn = mysql.connector.connect(**DB_CONFIG)
    cur = conn.cursor()

    ground_truth = {"brute_force_events": [], "spike_events": [], "crash_events": []}

    for server_id in SERVERS:
        sessions = gen_sessions(server_id)
        cur.executemany(
            "INSERT INTO Logs (Server_ID, Log_ID, Startup, Shutdown, Cost) VALUES (%s,%s,%s,%s,%s)",
            sessions
        )
        conn.commit()

        metric_id, app_id, sec_id, prod_id = 1, 1, 1, 1
        n_sessions = len(sessions)

        # Pick a few sessions per server to inject anomalies into, with known ground truth
        spike_sessions = set(random.sample(range(n_sessions), max(1, n_sessions // 15)))
        bf_sessions = set(random.sample(range(n_sessions), max(1, n_sessions // 20)))
        crash_sessions = set(random.sample(range(n_sessions), max(1, n_sessions // 25)))

        metrics_batch, app_batch, sec_batch, prod_batch = [], [], [], []

        for idx, (sid_, log_id, startup, shutdown, cost) in enumerate(sessions):
            spike_at = startup + (shutdown - startup) * random.random() if idx in spike_sessions else None
            bf_ip = f"203.0.113.{random.randint(2,254)}" if idx in bf_sessions else None
            bf_at = startup + (shutdown - startup) * random.random() if bf_ip else None
            crash_at = startup + (shutdown - startup) * random.random() if idx in crash_sessions else None

            m_rows, metric_id = gen_metrics_for_session(server_id, log_id, startup, shutdown, metric_id, spike_at)
            a_rows, app_id = gen_app_logs_for_session(server_id, log_id, startup, shutdown, app_id)
            s_rows, sec_id = gen_security_logs_for_session(server_id, log_id, startup, shutdown, sec_id, bf_ip, bf_at)
            p_rows, prod_id = gen_production_logs_for_session(server_id, log_id, startup, shutdown, prod_id, crash_at)

            metrics_batch.extend(m_rows)
            app_batch.extend(a_rows)
            sec_batch.extend(s_rows)
            prod_batch.extend(p_rows)

            if spike_at:
                ground_truth["spike_events"].append((server_id, log_id, str(spike_at)))
            if bf_ip:
                ground_truth["brute_force_events"].append((server_id, bf_ip, str(bf_at)))
            if crash_at:
                ground_truth["crash_events"].append((server_id, log_id, str(crash_at)))

            if len(app_batch) > 20000:
                cur.executemany("INSERT INTO Server_Metrics_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", metrics_batch)
                cur.executemany("INSERT INTO Application_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)", app_batch)
                cur.executemany("INSERT INTO Security_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", sec_batch)
                cur.executemany("INSERT INTO Production_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", prod_batch)
                conn.commit()
                metrics_batch, app_batch, sec_batch, prod_batch = [], [], [], []

        if app_batch or metrics_batch or sec_batch or prod_batch:
            if metrics_batch:
                cur.executemany("INSERT INTO Server_Metrics_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", metrics_batch)
            if app_batch:
                cur.executemany("INSERT INTO Application_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)", app_batch)
            if sec_batch:
                cur.executemany("INSERT INTO Security_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", sec_batch)
            if prod_batch:
                cur.executemany("INSERT INTO Production_Logs VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", prod_batch)
            conn.commit()

        print(f"Server {server_id}: {n_sessions} sessions, "
              f"{metric_id-1} metrics, {app_id-1} app logs, {sec_id-1} security logs, {prod_id-1} prod logs")

    cur.close()
    conn.close()

    import json
    with open("proof/ground_truth.json", "w") as f:
        json.dump(ground_truth, f, indent=2)
    print("\nGround truth (injected anomalies) written to proof/ground_truth.json")
    print(f"  Brute-force bursts injected: {len(ground_truth['brute_force_events'])}")
    print(f"  CPU/memory spikes injected:  {len(ground_truth['spike_events'])}")
    print(f"  Crash events injected:       {len(ground_truth['crash_events'])}")


if __name__ == "__main__":
    main()
