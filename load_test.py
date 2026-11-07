#!/usr/bin/env python3
"""Bounded AetherLake write-path load test; latency is per INSERT transaction."""

import argparse
import asyncio
from collections import Counter
from dataclasses import dataclass, field
import json
import math
import os
from pathlib import Path
import random
import statistics
import string
import sys
import time

import asyncpg

EVENT_TYPES = ["order.created", "order.updated", "order.cancelled", "payment.captured", "shipment.dispatched"]


def random_payload(size_bytes):
    return {"order_id": f"O-{random.randint(1, 10_000_000)}",
            "filler": "".join(random.choices(string.ascii_letters, k=max(0, size_bytes - 40)))}


@dataclass
class WorkerStats:
    rows: int = 0
    transactions: int = 0
    attempted_rows: int = 0
    latencies_ms: list = field(default_factory=list)
    errors: Counter = field(default_factory=Counter)


def record_error(stats, phase, exc):
    code = getattr(exc, "sqlstate", None) or type(exc).__name__
    stats.errors[f"{phase}:{code}"] += 1
    print(f"Load test stopped: {phase}:{code}", file=sys.stderr)


def connection_options(args):
    return dict(host=args.host, port=args.port, user=args.user, password=args.password,
                database=args.db, timeout=args.connect_timeout,
                command_timeout=args.statement_timeout,
                server_settings={"statement_timeout": str(max(1, int(args.statement_timeout * 1000))),
                                 "application_name": "aetherlake-load-test"})


async def read_counts(args):
    conn = await asyncpg.connect(**connection_options(args))
    try:
        rows = await conn.fetchval("SELECT count(*) FROM aetherlake.events")
        snapshots = await conn.fetchval("""
            SELECT jsonb_array_length(lake_iceberg.metadata(metadata_location)->'snapshots')
            FROM iceberg_tables
            WHERE table_namespace='aetherlake' AND table_name='events'
        """)
        return rows, snapshots
    finally:
        await conn.close(timeout=args.connect_timeout)


async def worker(conn, args, stop, stats, all_stats):
    while not stop.is_set():
        batch = args.batch_size
        if args.total_inserts:
            batch = min(batch, args.total_inserts - sum(s.attempted_rows for s in all_stats))
        if batch <= 0:
            return
        values = ", ".join(f"(${i}, ${i+1}, ${i+2}::jsonb)" for i in range(1, batch * 3 + 1, 3))
        params = []
        for _ in range(batch):
            params.extend((random.randint(1, args.tenants), random.choice(EVENT_TYPES),
                           json.dumps(random_payload(args.payload_size))))
        stats.attempted_rows += batch
        started = time.perf_counter()
        try:
            await conn.execute(f"INSERT INTO aetherlake.events(tenant_id,event_type,payload) VALUES {values}", *params)
        except Exception as exc:
            record_error(stats, "statement", exc)
            stop.set()
            return
        stats.rows += batch
        stats.transactions += 1
        stats.latencies_ms.append((time.perf_counter() - started) * 1000)


def percentile(data, pct):
    if not data:
        return None
    data = sorted(data)
    k = (len(data) - 1) * pct / 100
    low, high = int(k), min(int(k) + 1, len(data) - 1)
    return data[low] + (data[high] - data[low]) * (k - low)


async def run(args, stop=None):
    stop = stop if stop is not None else asyncio.Event()
    stats = [WorkerStats() for _ in range(args.connections)]
    conns, tasks = [], []
    before = after = (None, None)
    elapsed = window = 0.0
    cpu_started = time.process_time()
    try:
        before = await read_counts(args)
        conns = await asyncio.gather(*(asyncpg.connect(**connection_options(args))
                                     for _ in stats), return_exceptions=True)
        for stat, conn in zip(stats, conns):
            if isinstance(conn, BaseException):
                record_error(stat, "connect", conn)
                stop.set()
        if not stop.is_set():
            started = time.perf_counter()
            cpu_started = time.process_time()
            tasks = [asyncio.create_task(worker(conn, args, stop, stat, stats))
                     for conn, stat in zip(conns, stats)]
            await asyncio.wait(tasks, timeout=args.duration, return_when=asyncio.FIRST_COMPLETED)
            window = time.perf_counter() - started
            stop.set()
            _, pending = await asyncio.wait(tasks, timeout=args.drain_timeout)
            if pending:
                record_error(stats[0], "drain", TimeoutError())
                for task in pending:
                    task.cancel()
                for conn in conns:
                    conn.terminate()
            outcomes = await asyncio.gather(*tasks, return_exceptions=True)
            for stat, outcome in zip(stats, outcomes):
                if isinstance(outcome, BaseException):
                    record_error(stat, "worker", outcome)
            elapsed = time.perf_counter() - started
    except Exception as exc:
        record_error(stats[0], "setup", exc)
    finally:
        stop.set()
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        for conn in conns:
            if isinstance(conn, BaseException) or conn.is_closed():
                continue
            try:
                await conn.close(timeout=args.connect_timeout)
            except Exception as exc:
                record_error(stats[0], "close", exc)
                conn.terminate()
    cpu_seconds = time.process_time() - cpu_started
    try:
        after = await read_counts(args)
    except Exception as exc:
        record_error(stats[0], "reconcile", exc)
    errors = sum((s.errors for s in stats), Counter())
    rows = sum(s.rows for s in stats)
    transactions = sum(s.transactions for s in stats)
    latencies = [v for s in stats for v in s.latencies_ms]
    reconciled = before[0] is not None and after[0] is not None and after[0] - before[0] == rows
    snapshots_available = before[1] is not None and after[1] is not None
    snapshot_delta = after[1] - before[1] if snapshots_available else None
    target_met = args.total_inserts is None or rows == args.total_inserts
    return dict(
        valid=not errors and rows > 0 and reconciled and target_met and snapshots_available,
        config={k: getattr(args, k) for k in ("connections", "batch_size", "duration", "total_inserts",
                                             "payload_size", "tenants", "connect_timeout", "statement_timeout", "drain_timeout")},
        elapsed_seconds=elapsed, load_window_seconds=window, drain_seconds=max(0, elapsed-window),
        client_cpu_seconds=cpu_seconds, committed_rows=rows, successful_transactions=transactions,
        attempted_rows=sum(s.attempted_rows for s in stats), errors=dict(errors),
        failed_statements=sum(v for k, v in errors.items() if k.startswith("statement:")),
        row_count_before=before[0], row_count_after=after[0], rows_reconciled=reconciled,
        target_met=target_met, rows_per_second=rows/elapsed if elapsed else 0,
        transactions_per_second=transactions/elapsed if elapsed else 0,
        latency_ms=dict(unit="successful INSERT transaction", avg=statistics.mean(latencies) if latencies else None,
                        p50=percentile(latencies, 50), p95=percentile(latencies, 95),
                        p99=percentile(latencies, 99), max=max(latencies) if latencies else None),
        retained_snapshots_before=before[1], retained_snapshots_after=after[1],
        retained_snapshot_delta=snapshot_delta,
        retained_snapshots_per_second=snapshot_delta/elapsed if snapshots_available and elapsed else None,
    )


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default=os.environ.get("POSTGRES_HOST", "localhost"))
    p.add_argument("--port", type=int, default=int(os.environ.get("POSTGRES_PORT", "5432")))
    p.add_argument("--user", default=os.environ.get("POSTGRES_USER"))
    p.add_argument("--password", default=os.environ.get("POSTGRES_PASSWORD"))
    p.add_argument("--db", default=os.environ.get("POSTGRES_DB"))
    p.add_argument("--connections", type=int, default=10)
    p.add_argument("--duration", type=float, default=30.0, help="Maximum load window, including total-inserts mode")
    p.add_argument("--total-inserts", type=int)
    p.add_argument("--payload-size", type=int, default=200)
    p.add_argument("--tenants", type=int, default=1000)
    p.add_argument("--batch-size", type=int, default=1, help="Rows per INSERT transaction")
    p.add_argument("--connect-timeout", type=float, default=10)
    p.add_argument("--statement-timeout", type=float, default=10)
    p.add_argument("--drain-timeout", type=float, default=12)
    p.add_argument("--output", type=Path, help="Write a credential-free JSON result")
    args = p.parse_args(argv)
    for name in ("connections", "duration", "tenants", "batch_size", "connect_timeout", "statement_timeout", "drain_timeout"):
        value = getattr(args, name)
        if not math.isfinite(value) or value <= 0:
            p.error(f"--{name.replace('_', '-')} must be positive and finite")
    if args.batch_size > 32767 // 3 or args.payload_size < 0 or (args.total_inserts is not None and args.total_inserts <= 0):
        p.error("batch exceeds PostgreSQL's parameter limit, payload is negative, or total-inserts is not positive")
    if not all((args.user, args.password, args.db)):
        p.error("Missing user/password/db; source .env first")
    return args


if __name__ == "__main__":
    arguments = parse_args()
    result = asyncio.run(run(arguments))
    print(json.dumps(result, indent=2))
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(result, indent=2) + "\n")
    sys.exit(0 if result["valid"] else 1)
