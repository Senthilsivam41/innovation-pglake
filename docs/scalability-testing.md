# SCAL-01: write-path scalability testing

The benchmark characterizes the existing PostgreSQL → pg_lake → MinIO write path,
including its outbox trigger. It does not establish a production SLO or measure
Spark/Databricks consumption. Use a development Docker context with the pinned
images already built (`make build`). No server tuning or staging-table redesign
is part of the experiment.

## Run

```bash
python3 -m venv .aetherlake/loadtest-venv
.aetherlake/loadtest-venv/bin/pip install -r requirements-loadtest.txt
.aetherlake/loadtest-venv/bin/python -m unittest discover -s tests -p 'test_load_test.py' -v
.aetherlake/loadtest-venv/bin/python scripts/run-scalability.py --smoke
.aetherlake/loadtest-venv/bin/python scripts/run-scalability.py
```

The runner explicitly uses `docker-compose.yml` and `.env.example`, clears shell
overrides for the fixture's keys, assigns a unique Compose project and dynamic
ports, and creates fresh volumes for every repetition. It never sources `.env`
or resets the existing demo. It removes only its own disposable stack and volumes
after each point. Synthetic test data is intentionally discarded; results remain
under `.aetherlake/load-tests/<run-id>/` (or a new `--output-dir`).

Before any writes, free space on MinIO `/data` must exceed the greater of 20 GiB
or 20% of its filesystem. The same guard is sampled during the load. The manifest
records image IDs, architecture, Docker CPU/memory capacity, existing container
count, Python/asyncpg versions, PostgreSQL settings with units, extensions, schema,
partition specification, source commit and source hashes. Shared-host interference
is a limitation: other running containers are not stopped or retuned.

## Protocol

1. A five-second dry run uses one connection and one row per INSERT.
2. Every subsequent repetition starts with two seed rows and a fixed ten-row,
   ten-transaction warmup. This checks the writer and gives each measurement the
   same starting row/snapshot counts. Warmup time and connection setup are excluded.
3. Measure batches **1, 10, 50, 100** across **1, 2, 4, 8, 16** connections,
   three 30-second repetitions per eligible cell. Payloads are approximately 1 KiB
   across 1,000 synthetic tenants. A batch is one autocommit INSERT transaction.
4. On any error, stop that repetition and skip its remaining repetitions and
   higher concurrency for that batch. Keep the failed result and PostgreSQL log
   tail. Capacity/monitor failures stop the experiment rather than escalating.
5. Confirm the two fastest error-free cells for 120 seconds each, then run the
   fastest surviving configuration for ten minutes. Record an unsuccessful
   confirmation/sustained run as a finding; do not hide it behind automatic retries.

`--smoke` uses two batches, two concurrency levels, one three-second repetition,
and no sustained phase. Its numbers are runner verification only.

Cron jobs are paused only in each disposable stack. An already-running scheduled
job invalidates that repetition. This isolates foreground writes; production
maintenance contention and retention behavior require a separate staging test.

## Interpret results

`manifest.json`, per-point JSON, and `summary.csv` retain successful and failed
measurements. Workers stop on their first error. Errors are counted per failed
statement with SQLSTATE (or exception class), independently of attempted rows.
Rows/sec and successful INSERT transactions/sec are distinct. p50/p95/p99 measure
successful INSERT transaction latency, excluding client payload generation;
throughput includes payload generation and bounded in-flight drain. Connection
startup and post-run reconciliation are excluded. Report the actual load window
and drain duration with the rates. Client CPU includes payload generation.

Every valid result must have no errors and reconcile the database row delta with
the committed-row counter. Snapshots are **retained snapshot deltas**, not a
general publication counter. For these isolated, maintenance-paused runs, the
runner additionally requires the snapshot delta to equal successful transactions
before accepting the point. Do not reuse that publication interpretation when
retention, maintenance, or other writers are active.

Resource samples include Docker CPU/memory/block-I/O strings, filesystem free
bytes, and PostgreSQL wait-event counts approximately every five seconds. Short
lock episodes can occur between samples; use SQLSTATE and the failure log as
additional evidence. JSON omits passwords and connection URLs.

Report medians and ranges across repetitions, per-run latency percentiles, raw
errors, bucket object/byte growth, and the confirmed sustained result. A plateau
requires multiple valid concurrency levels with diminishing throughput gains.
If escalation instead fails, report a concurrency failure boundary, not a plateau.
Without a user-specified throughput and latency target, the outcome is measured
capacity for this environment and workload, not production acceptance.

## Standalone CLI

The original environment-based connection flags remain supported. Results are now
printed as readable JSON; `--output <path>` also persists them. Latency is per
INSERT transaction. Exit status is nonzero for errors, missing snapshot metrics,
row mismatch, or failure to reach `--total-inserts`. Duration bounds both modes;
inserts may drain for up to `--drain-timeout` after the requested load window.
Connect and statement timeouts default to ten seconds; drain defaults to twelve.
There are no automatic retries or hidden partial successes.

The standalone CLI does not manage capacity or dataset isolation. Prefer the
matrix runner for experiments, and never point it at a production database.
