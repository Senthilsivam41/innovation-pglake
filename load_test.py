#!/usr/bin/env python3
"""AetherLake write-path load test."""

import argparse
import asyncio
import json
import os
import random
import statistics
import string
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

import asyncpg

EVENT_TYPES = [
    "order.created",
    "order.updated",
    "order.cancelled",
    "payment.captured",
    "shipment.dispatched",
]


def random_payload(size_bytes: int) -> dict:
    filler = "".join(random.choices(string.ascii_letters, k=max(0, size_bytes - 40)))
    return {"order_id": f"O-{random.randint(1, 10_000_000)}", "filler": filler}


# The twelve wellbores seeded by docker/postgres/init/09-seed-well-production.sql.
WELLBORES = [
    f"{well}-T{bore}"
    for well in ("DRA-A1", "DRA-A2", "DRA-B3", "NJO-C1", "NJO-C2", "NJO-D4")
    for bore in (1, 2)
]

TARGETS = {
    "events": ("aetherlake", "events"),
    "measurements": ("dm_dom_well_production", "production_measurement"),
}


def measurement_row(index: int, anchor: float) -> tuple:
    """One production reading. Rates vary per wellbore so the aggregate is not degenerate."""
    wellbore = WELLBORES[index % len(WELLBORES)]
    base = 900 + (hash(wellbore) % 700)
    measured_at = datetime.fromtimestamp(anchor - random.random() * 365 * 86400, tz=timezone.utc)
    return (
        "inst_well_production",
        f"{wellbore}:{measured_at.isoformat()}:{index}",
        wellbore,
        measured_at,
        round(base * random.uniform(0.85, 1.15), 2),
        round(base * 0.62 * random.uniform(0.85, 1.15), 2),
        round(base * random.uniform(0.15, 0.45), 2),
        round(random.uniform(90.0, 130.0), 2),
        62.0 if wellbore.endswith("-T2") else 78.0,
        "good" if random.random() > 0.02 else "suspect",
    )


@dataclass
class WorkerStats:
    count: int = 0
    latencies_ms: list = field(default_factory=list)
    errors: int = 0


async def worker(worker_id, dsn, stop_event, stats: WorkerStats, payload_size, tenant_range,
                 batch_size, target="events"):
    conn = await asyncpg.connect(dsn)
    columns = 3 if target == "events" else 10
    values_sql = ", ".join(
        "(" + ", ".join(
            f"${row * columns + col + 1}" + ("::jsonb" if target == "events" and col == 2 else "")
            for col in range(columns)
        ) + ")"
        for row in range(batch_size)
    )
    if target == "events":
        insert_sql = f"INSERT INTO aetherlake.events(tenant_id, event_type, payload) VALUES {values_sql}"
    else:
        insert_sql = (
            "INSERT INTO dm_dom_well_production.production_measurement"
            "(space, record_id, wellbore, measured_at, oil_rate_bpd, gas_rate_mscfd,"
            " water_rate_bpd, tubing_head_pressure_bar, choke_percent, quality)"
            f" VALUES {values_sql}"
        )
    anchor = time.time()
    sequence = worker_id * 10 ** 9
    try:
        while not stop_event.is_set():
            params = []
            for _ in range(batch_size):
                if target == "events":
                    params.extend((
                        random.randint(1, tenant_range),
                        random.choice(EVENT_TYPES),
                        json.dumps(random_payload(payload_size)),
                    ))
                else:
                    sequence += 1
                    params.extend(measurement_row(sequence, anchor))
            start = time.perf_counter()
            try:
                await conn.execute(insert_sql, *params)
                stats.count += batch_size
                stats.latencies_ms.append((time.perf_counter() - start) * 1000)
            except Exception as exc:
                stats.errors += batch_size
                if stats.errors <= 5:
                    print(f"[worker {worker_id}] insert error: {exc}", file=sys.stderr)
    finally:
        await conn.close()


async def get_snapshot_count(dsn, target="events") -> int:
    namespace, table = TARGETS[target]
    conn = await asyncpg.connect(dsn)
    try:
        row = await conn.fetchrow(
            """
            SELECT jsonb_array_length(meta->'snapshots') AS snapshot_count
            FROM (
                SELECT lake_iceberg.metadata(metadata_location) AS meta
                FROM iceberg_tables
                WHERE table_namespace = $1 AND table_name = $2
            ) t
            """,
            namespace, table,
        )
        return row["snapshot_count"] if row and row["snapshot_count"] is not None else -1
    except Exception as exc:
        print(f"(snapshot count query failed: {exc})", file=sys.stderr)
        return -1
    finally:
        await conn.close()


async def get_row_count(dsn, target="events") -> int:
    namespace, table = TARGETS[target]
    conn = await asyncpg.connect(dsn)
    try:
        row = await conn.fetchrow(f"SELECT count(*) AS n FROM {namespace}.{table}")
        return row["n"]
    finally:
        await conn.close()


def percentile(data, pct):
    if not data:
        return 0.0
    data = sorted(data)
    k = (len(data) - 1) * (pct / 100)
    f, c = int(k), min(int(k) + 1, len(data) - 1)
    return data[f] if f == c else data[f] + (data[c] - data[f]) * (k - f)


async def run(args):
    dsn = f"postgresql://{args.user}:{args.password}@{args.host}:{args.port}/{args.db}"
    print(f"Connecting to {args.host}:{args.port}/{args.db} as {args.user}")
    print(f"Concurrency: {args.connections} connections")
    print(f"Batch size: {args.batch_size} rows/statement")
    print(f"Target: {args.total_inserts} total inserts" if args.total_inserts else f"Duration: {args.duration}s")
    print(f"Writing to: {TARGETS[args.target][0]}.{TARGETS[args.target][1]}")
    print(f"Payload size: ~{args.payload_size} bytes\n")

    row_count_before = await get_row_count(dsn, args.target)
    snapshot_before = await get_snapshot_count(dsn, args.target)
    stop_event = asyncio.Event()
    stats_list = [WorkerStats() for _ in range(args.connections)]
    start_time = time.perf_counter()
    tasks = [asyncio.create_task(worker(i, dsn, stop_event, stats_list[i], args.payload_size, args.tenants, args.batch_size, args.target)) for i in range(args.connections)]
    if args.total_inserts:
        while sum(s.count for s in stats_list) < args.total_inserts:
            await asyncio.sleep(0.2)
    else:
        await asyncio.sleep(args.duration)
    stop_event.set()
    await asyncio.gather(*tasks)
    elapsed = time.perf_counter() - start_time

    row_count_after = await get_row_count(dsn, args.target)
    snapshot_after = await get_snapshot_count(dsn, args.target)
    total_inserts = sum(s.count for s in stats_list)
    all_latencies = [latency for stats in stats_list for latency in stats.latencies_ms]
    print("=" * 60)
    print("RESULTS")
    print("=" * 60)
    print(f"Duration:            {elapsed:.1f}s")
    print(f"Total inserts:       {total_inserts}")
    print(f"Errors:              {sum(s.errors for s in stats_list)}")
    print(f"Throughput:          {total_inserts / elapsed:.1f} inserts/sec")
    if all_latencies:
        print(f"Latency avg:         {statistics.mean(all_latencies):.2f} ms")
        for pct in (50, 95, 99):
            print(f"Latency p{pct}:         {percentile(all_latencies, pct):.2f} ms")
        print(f"Latency max:         {max(all_latencies):.2f} ms")
    print(f"\nRow count before:    {row_count_before}")
    print(f"Row count after:     {row_count_after}")
    print(f"Rows added:          {row_count_after - row_count_before}")
    if snapshot_before >= 0 and snapshot_after >= 0:
        delta = snapshot_after - snapshot_before
        print(f"\nIceberg snapshots before: {snapshot_before}")
        print(f"Iceberg snapshots after:  {snapshot_after}")
        print(f"Snapshots published:      {delta}")
        print(f"Avg snapshot publish rate: {delta / elapsed:.2f} snapshots/sec" if delta > 0 else "Avg snapshot publish rate: 0.00 snapshots/sec")
    else:
        print("\nIceberg snapshot count unavailable — check the catalog query against the actual schema.")
    print("=" * 60)


def parse_args():
    p = argparse.ArgumentParser(description="AetherLake write-path load test")
    p.add_argument("--host", default=os.environ.get("POSTGRES_HOST", "localhost"))
    p.add_argument("--port", type=int, default=int(os.environ.get("POSTGRES_PORT", "5432")))
    p.add_argument("--user", default=os.environ.get("POSTGRES_USER"))
    p.add_argument("--password", default=os.environ.get("POSTGRES_PASSWORD"))
    p.add_argument("--db", default=os.environ.get("POSTGRES_DB"))
    p.add_argument("--connections", type=int, default=10)
    p.add_argument("--duration", type=float, default=30.0)
    p.add_argument("--total-inserts", type=int, default=None)
    p.add_argument("--payload-size", type=int, default=200)
    p.add_argument("--tenants", type=int, default=1000)
    p.add_argument("--batch-size", type=int, default=1, help="Rows per INSERT statement")
    p.add_argument("--target", choices=sorted(TARGETS), default="events",
                   help="events hammers the original contract table; measurements writes "
                        "production readings into the enterprise model's record container")
    args = p.parse_args()
    if args.batch_size < 1:
        p.error("--batch-size must be at least 1")
    missing = [name for name, value in (("--user", args.user), ("--password", args.password), ("--db", args.db)) if not value]
    if missing:
        p.error(f"Missing {', '.join(missing)}; source .env first")
    return args


if __name__ == "__main__":
    asyncio.run(run(parse_args()))
