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


@dataclass
class WorkerStats:
    count: int = 0
    latencies_ms: list = field(default_factory=list)
    errors: int = 0


async def worker(worker_id, dsn, stop_event, stats: WorkerStats, payload_size, tenant_range, batch_size):
    conn = await asyncpg.connect(dsn)
    values_sql = ", ".join(
        f"(${i}, ${i + 1}, ${i + 2}::jsonb)" for i in range(1, batch_size * 3 + 1, 3)
    )
    insert_sql = f"INSERT INTO aetherlake.events(tenant_id, event_type, payload) VALUES {values_sql}"
    try:
        while not stop_event.is_set():
            params = []
            for _ in range(batch_size):
                params.extend((
                    random.randint(1, tenant_range),
                    random.choice(EVENT_TYPES),
                    json.dumps(random_payload(payload_size)),
                ))
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


async def get_snapshot_count(dsn) -> int:
    conn = await asyncpg.connect(dsn)
    try:
        row = await conn.fetchrow(
            """
            SELECT jsonb_array_length(meta->'snapshots') AS snapshot_count
            FROM (
                SELECT lake_iceberg.metadata(metadata_location) AS meta
                FROM iceberg_tables
                WHERE table_namespace = 'aetherlake' AND table_name = 'events'
            ) t
            """
        )
        return row["snapshot_count"] if row and row["snapshot_count"] is not None else -1
    except Exception as exc:
        print(f"(snapshot count query failed: {exc})", file=sys.stderr)
        return -1
    finally:
        await conn.close()


async def get_row_count(dsn) -> int:
    conn = await asyncpg.connect(dsn)
    try:
        row = await conn.fetchrow("SELECT count(*) AS n FROM aetherlake.events")
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
    print(f"Payload size: ~{args.payload_size} bytes\n")

    row_count_before, snapshot_before = await get_row_count(dsn), await get_snapshot_count(dsn)
    stop_event = asyncio.Event()
    stats_list = [WorkerStats() for _ in range(args.connections)]
    start_time = time.perf_counter()
    tasks = [asyncio.create_task(worker(i, dsn, stop_event, stats_list[i], args.payload_size, args.tenants, args.batch_size)) for i in range(args.connections)]
    if args.total_inserts:
        while sum(s.count for s in stats_list) < args.total_inserts:
            await asyncio.sleep(0.2)
    else:
        await asyncio.sleep(args.duration)
    stop_event.set()
    await asyncio.gather(*tasks)
    elapsed = time.perf_counter() - start_time

    row_count_after, snapshot_after = await get_row_count(dsn), await get_snapshot_count(dsn)
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
    args = p.parse_args()
    if args.batch_size < 1:
        p.error("--batch-size must be at least 1")
    missing = [name for name, value in (("--user", args.user), ("--password", args.password), ("--db", args.db)) if not value]
    if missing:
        p.error(f"Missing {', '.join(missing)}; source .env first")
    return args


if __name__ == "__main__":
    asyncio.run(run(parse_args()))
