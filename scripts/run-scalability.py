#!/usr/bin/env python3
"""Run SCAL-01 on disposable Compose volumes; never targets the existing demo."""
import argparse
import asyncio
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import load_test as load


def command(argv, env, timeout=30):
    return subprocess.run(argv, cwd=ROOT, env=env, check=True, capture_output=True,
                          text=True, timeout=timeout).stdout.strip()


async def measure(args, compose, env):
    stop = asyncio.Event()
    samples, guard_errors = [], []
    ids = command(compose + ["ps", "-q"], env).splitlines()

    def sample():
        fields = command(compose + ["exec", "-T", "minio", "df", "-Pk", "/data"], env).splitlines()[-1].split()
        total, free = int(fields[-5])*1024, int(fields[-3])*1024
        if free < max(20*1024**3, total*0.2):
            raise RuntimeError("MinIO free space below reserve (20 GiB or 20%, whichever is larger)")
        stats = command(["docker", "stats", "--no-stream", "--format", "{{json .}}", *ids], env)
        waits = command(compose + ["exec", "-T", "postgres", "psql", "-X", "-U", args.user, "-d", args.db, "-Atqc",
            "SELECT coalesce(json_agg(t), '[]') FROM (SELECT wait_event_type,wait_event,count(*) FROM pg_stat_activity "
            "WHERE application_name='aetherlake-load-test' GROUP BY 1,2) t"], env)
        return dict(time=datetime.now(timezone.utc).isoformat(), minio_free_bytes=free,
                    containers=[json.loads(line) for line in stats.splitlines()], waits=json.loads(waits))

    async def monitor():
        while not stop.is_set():
            try:
                samples.append(await asyncio.to_thread(sample))
            except Exception as exc:
                guard_errors.append(str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__)
                stop.set()
            try:
                await asyncio.wait_for(stop.wait(), timeout=5)
            except TimeoutError:
                pass

    # Capacity is checked synchronously before the first write as well as during load.
    samples.append(await asyncio.to_thread(sample))
    watcher = asyncio.create_task(monitor())
    try:
        result = await load.run(args, stop)
    finally:
        stop.set()
        await watcher
    result.update(resources=samples, guard_errors=guard_errors)
    result["valid"] = result["valid"] and not guard_errors
    # Maintenance is paused on this disposable stack; require the snapshot ledger to reconcile.
    result["snapshots_reconciled"] = result["retained_snapshot_delta"] == result["successful_transactions"]
    result["valid"] = result["valid"] and result["snapshots_reconciled"]
    return result


def resume_manifest(saved, current):
    if saved.get("complete") or not saved.get("interrupted"):
        raise ValueError("Only an interrupted experiment can resume; failed results must not be retried")
    for key in ("smoke", "docker", "images", "python", "asyncpg", "docker_context", "write_role"):
        if saved.get(key) != current.get(key):
            raise ValueError(f"Resume environment changed: {key}; start a separate experiment")
    if saved["source_hashes"]["load_test.py"] != current["source_hashes"]["load_test.py"]:
        raise ValueError("Measurement harness changed; start a separate experiment")
    current["previous_interruption_reason"] = saved.pop("interruption_reason", None)
    saved.setdefault("resume_sessions", []).append(current)
    saved.setdefault("interrupted_points", []).extend(p for p in saved["points"] if p.get("interrupted"))
    saved["points"] = [p for p in saved["points"] if not p.get("interrupted")]
    saved["interrupted"] = False
    return saved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true", help="Short runner verification, not a capacity result")
    destination = parser.add_mutually_exclusive_group()
    destination.add_argument("--output-dir", type=Path)
    destination.add_argument("--resume", type=Path, help="Continue an interrupted run; retain completed and failed points")
    cli = parser.parse_args()
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    output = cli.resume or cli.output_dir or ROOT / ".aetherlake" / "load-tests" / run_id
    if not cli.resume:
        output.mkdir(parents=True, exist_ok=False)
    project = "aetherlake-scal-" + run_id.lower()
    env = dict(os.environ)
    # Let Compose parse the fixture, and prevent shell overrides from targeting another storage service.
    for line in (ROOT / ".env.example").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            env.pop(line.split("=", 1)[0], None)
    env.update(POSTGRES_PORT="0", MINIO_API_PORT="0", MINIO_CONSOLE_PORT="0", DEMO_UI_PORT="0")
    compose = ["docker", "compose", "-f", str(ROOT / "docker-compose.yml"), "-p", project,
               "--env-file", str(ROOT / ".env.example")]
    config = json.loads(command(compose + ["config", "--format", "json"], env))
    pg_env = config["services"]["postgres"]["environment"]
    manifest = dict(run_id=run_id, smoke=cli.smoke, complete=False,
                    source_commit=command(["git", "rev-parse", "HEAD"], env),
                    source_dirty=bool(command(["git", "status", "--porcelain"], env)),
                    source_hashes={p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest()
                                   for p in ("load_test.py", "scripts/run-scalability.py")},
                    host=platform.platform(), maintenance="cron jobs paused in disposable stack",
                    payload_size=1024, tenants=1000, points=[])
    info = json.loads(command(["docker", "info", "--format", "{{json .}}"], env))
    manifest["docker"] = {k: info[k] for k in ("NCPU", "MemTotal", "ServerVersion", "Architecture")}
    manifest["other_running_containers"] = len(command(["docker", "ps", "-q"], env).splitlines())
    images = [config["services"][s]["image"] for s in ("postgres", "pgduck", "minio")]
    image_lines = command(["docker", "image", "inspect", "--format",
        '{"id":{{json .Id}},"digests":{{json .RepoDigests}},"architecture":{{json .Architecture}}}', *images], env)
    manifest["images"] = [json.loads(line) for line in image_lines.splitlines()]
    manifest["python"] = platform.python_version()
    manifest["asyncpg"] = load.asyncpg.__version__
    manifest["docker_context"] = command(["docker", "context", "show"], env)
    manifest["write_role"] = pg_env["POSTGRES_USER"]
    if cli.resume:
        saved = json.loads((output / "manifest.json").read_text())
        if command(["git", "diff", "--name-only", saved["source_commit"], "--",
                    "docker-compose.yml", ".env.example", "docker"], env):
            parser.error("Compose fixture or server contract changed; start a separate experiment")
        try:
            (output / f"manifest-before-resume-{run_id}.json").write_text(json.dumps(saved, indent=2) + "\n")
            manifest = resume_manifest(saved, manifest)
        except ValueError as exc:
            parser.error(str(exc))
    completed = {p["label"]: p for p in manifest["points"] if not p.get("skipped")}

    def save():
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        fields = ["label", "resume_session", "connections", "batch_size", "valid", "skipped", "committed_rows", "successful_transactions",
                  "rows_per_second", "transactions_per_second", "p50_ms", "p95_ms", "p99_ms",
                  "retained_snapshots_per_second", "failed_statements", "errors", "runner_error"]
        with (output / "summary.csv").open("w", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=fields)
            writer.writeheader()
            for point in manifest["points"]:
                row = {key: point.get(key) for key in fields}
                row["resume_session"] = point.get("resume_session", 0)
                row.update({f"p{n}_ms": point.get("latency_ms", {}).get(f"p{n}") for n in (50, 95, 99)})
                row["errors"] = json.dumps(point.get("errors", {}), sort_keys=True)
                writer.writerow(row)

    def sql(query):
        return command(compose + ["exec", "-T", "postgres", "psql", "-X", "-v", "ON_ERROR_STOP=1",
                                   "-U", pg_env["POSTGRES_USER"], "-d", pg_env["POSTGRES_DB"], "-Atqc", query], env)

    def bucket():
        text = command(compose + ["run", "--rm", "--no-deps", "--entrypoint", "sh", "minio-init", "-c",
            'mc alias set bench http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && '
            'mc du --json "bench/$S3_BUCKET"'], env)
        return [json.loads(line) for line in text.splitlines()]

    def point(label, connections, batch, duration, warmup=True):
        if label in completed:
            result = completed[label]
            config = result.get("config", {})
            if (config.get("connections"), config.get("batch_size"), config.get("duration")) != (connections, batch, duration):
                raise RuntimeError(f"Saved configuration mismatch for {label}")
            print(f"{label}: preserved saved result (valid={result['valid']})", flush=True)
            return result
        print(f"{label}: connections={connections}, batch={batch}, duration={duration}s", flush=True)
        result = dict(label=label, connections=connections, batch_size=batch, valid=False,
                      resume_session=len(manifest.get("resume_sessions", [])),
                      config=dict(connections=connections, batch_size=batch, duration=duration))
        try:
            command(compose + ["up", "-d", "--no-build", "--wait", "--wait-timeout", "300", "postgres"], env, 330)
            sql("UPDATE cron.job SET active=false")
            if sql("SELECT count(*) FROM cron.job_run_details WHERE status='running'") != "0":
                raise RuntimeError("Scheduled maintenance already running; discard this repetition")
            settings = json.loads(sql("SELECT json_object_agg(name,json_build_object('value',setting,'unit',unit)) FROM pg_settings WHERE name IN "
                "('server_version','max_connections','max_worker_processes','max_parallel_workers','shared_buffers','work_mem')"))
            if manifest.get("postgres_settings", settings) != settings:
                raise RuntimeError("PostgreSQL settings changed; start a separate experiment")
            manifest["postgres_settings"] = settings
            if "extensions" not in manifest:
                manifest["extensions"] = json.loads(sql("SELECT json_agg(t) FROM (SELECT extname,extversion FROM pg_extension) t"))
                manifest["iceberg_contract"] = json.loads(sql("SELECT json_build_object('format_version',m->'format-version',"
                    "'schemas',m->'schemas','partition_specs',m->'partition-specs') FROM (SELECT "
                    "lake_iceberg.metadata(metadata_location) m FROM iceberg_tables WHERE "
                    "table_namespace='aetherlake' AND table_name='events') t"))
            port = int(command(compose + ["port", "postgres", "5432"], env).rsplit(":", 1)[1])
            args = load.parse_args(["--host", "127.0.0.1", "--port", str(port), "--user", pg_env["POSTGRES_USER"],
                "--password", pg_env["POSTGRES_PASSWORD"], "--db", pg_env["POSTGRES_DB"],
                "--connections", str(connections), "--batch-size", str(batch), "--duration", str(duration), "--payload-size", "1024"])
            random.seed(0)
            if warmup:
                warm = load.parse_args(["--host", args.host, "--port", str(port), "--user", args.user,
                    "--password", args.password, "--db", args.db, "--connections", "1", "--total-inserts", "10", "--duration", "30",
                    "--payload-size", "1024"])
                result["warmup"] = asyncio.run(measure(warm, compose, env))
                if not result["warmup"]["valid"]:
                    raise RuntimeError("Fixed ten-transaction warmup failed")
            storage_before = bucket()
            result.update(asyncio.run(measure(args, compose, env)))
            result.update(label=label, storage_before=storage_before, storage_after=bucket())
            if not result["valid"]:
                result["postgres_log_tail"] = command(compose + ["logs", "--no-color", "--tail", "80", "postgres"], env)
        except Exception as exc:
            result.update(valid=False, runner_error=str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__)
            if isinstance(exc, RuntimeError) and ("MinIO free space" in str(exc) or "PostgreSQL settings changed" in str(exc)):
                result["guard_errors"] = [str(exc)]
        except KeyboardInterrupt:
            result.update(valid=False, interrupted=True, runner_error="user_pause")
            raise
        finally:
            manifest["points"].append(result)
            (output / f"{label}.json").write_text(json.dumps(result, indent=2) + "\n")
            save()
            command(compose + ["down", "--volumes", "--remove-orphans"], env, 90)
        print(f"{label}: valid={result['valid']}, rows/s={result.get('rows_per_second', 0):.2f}", flush=True)
        if result.get("guard_errors"):
            raise RuntimeError("Resource guard stopped the experiment")
        return result

    try:
        if not point("dry-run", 1, 1, 3 if cli.smoke else 5, warmup=False)["valid"]:
            raise RuntimeError("Low-concurrency dry run failed")
        candidates = []
        for batch in ([1, 10] if cli.smoke else [1, 10, 50, 100]):
            stopped = False
            for connections in ([1, 2] if cli.smoke else [1, 2, 4, 8, 16]):
                if stopped:
                    if not any(p.get("skipped") and p["connections"] == connections and p["batch_size"] == batch
                               for p in manifest["points"]):
                        manifest["points"].append(dict(label="skipped", connections=connections, batch_size=batch,
                                                       skipped=True, reason="lower concurrency failed for this batch"))
                    save()
                    continue
                repetitions = []
                for repeat in range(1 if cli.smoke else 3):
                    p = point(f"b{batch}-c{connections}-r{repeat+1}", connections, batch, 3 if cli.smoke else 30)
                    if not p["valid"]:
                        stopped = True
                        break
                    repetitions.append(p)
                if not stopped:
                    candidates.append((statistics.median(p["rows_per_second"] for p in repetitions), connections, batch))
        finalists = []
        if not cli.smoke:
            for _, connections, batch in sorted(candidates, reverse=True)[:2]:
                p = point(f"confirm-b{batch}-c{connections}", connections, batch, 120)
                if p["valid"]:
                    finalists.append((p["rows_per_second"], connections, batch))
            if not finalists:
                raise RuntimeError("No error-free configuration survived confirmation")
            _, connections, batch = max(finalists)
            manifest["sustained_valid"] = point("sustained", connections, batch, 600)["valid"]
        manifest["complete"] = True
    except Exception as exc:
        manifest["experiment_error"] = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
    except KeyboardInterrupt:
        manifest.update(interrupted=True, interruption_reason="User interrupted the experiment")
    finally:
        save()
    print(f"Results: {output}", flush=True)
    if manifest.get("interrupted"):
        return 130
    return 0 if manifest["complete"] and (cli.smoke or manifest.get("sustained_valid")) else 1


if __name__ == "__main__":
    sys.exit(main())
