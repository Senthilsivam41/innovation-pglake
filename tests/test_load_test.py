"""Deterministic accounting and deadline checks; no PostgreSQL required."""
import asyncio
import copy
from contextlib import redirect_stderr
import io
import importlib.util
import json
import unittest
from unittest.mock import AsyncMock, patch

import load_test as load
from pathlib import Path

spec = importlib.util.spec_from_file_location("matrix", Path(__file__).resolve().parents[1] / "scripts/run-scalability.py")
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class LoadTest(unittest.IsolatedAsyncioTestCase):
    async def test_capacity_guard_precedes_load(self):
        with patch.object(matrix, "command", side_effect=["container-id", "/dev/test 100000000 99000000 1000000 99% /data"]), \
             patch.object(load, "run", new_callable=AsyncMock) as run:
            with self.assertRaisesRegex(RuntimeError, "reserve"):
                await matrix.measure(None, ["docker"], {})
            run.assert_not_awaited()

    def test_resume_preserves_failures_and_rejects_changed_harness(self):
        saved = dict(complete=False, interrupted=True, smoke=False, source_hashes={"load_test.py": "same"},
                     points=[dict(label="passed", valid=True), dict(label="deadlock", valid=False, errors={"statement:40P01": 1}),
                             dict(label="paused", valid=False, interrupted=True)])
        current = dict(smoke=False, source_hashes={"load_test.py": "same"})
        resumed = matrix.resume_manifest(copy.deepcopy(saved), copy.deepcopy(current))
        self.assertEqual(resumed["points"], saved["points"][:2])
        self.assertEqual(resumed["interrupted_points"], saved["points"][2:])
        self.assertFalse(resumed["interrupted"])
        self.assertEqual(len(resumed["resume_sessions"]), 1)
        for mutation in (dict(source_hashes={"load_test.py": "changed"}), dict(smoke=True)):
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                matrix.resume_manifest(copy.deepcopy(saved), current | mutation)
        with self.assertRaises(ValueError):
            matrix.resume_manifest(saved | dict(complete=True), current)

    async def test_accounting_and_failures(self):
        for scenario in ("success", "statement", "connect", "drain", "target", "reconcile", "worker"):
            with self.subTest(scenario=scenario), redirect_stderr(io.StringIO()):
                args = load.parse_args(["--user", "test", "--password", "not-for-output", "--db", "test",
                                        "--connections", "2", "--batch-size", "3", "--total-inserts", "7",
                                        "--duration", "0.02", "--drain-timeout", "0.01"])
                rows, commits = 2, 1

                async def execute(*params):
                    nonlocal rows, commits
                    await asyncio.sleep(0)
                    if scenario == "statement":
                        raise load.asyncpg.DeadlockDetectedError("fixture")
                    if scenario in ("drain", "target"):
                        await asyncio.sleep(1 if scenario == "drain" else 0.03)
                    rows += (len(params) - 1) // 3
                    commits += 1

                conn = AsyncMock()
                conn.execute.side_effect = execute
                conn.is_closed = lambda: False
                conn.terminate = lambda: None

                async def counts(_):
                    return rows + (1 if scenario == "reconcile" and commits > 1 else 0), commits

                connect = AsyncMock(return_value=conn)
                if scenario == "connect":
                    connect.side_effect = ConnectionError("fixture")
                if scenario == "worker":
                    payload = patch.object(load, "random_payload", side_effect=ValueError("fixture"))
                else:
                    payload = patch.object(load, "random_payload", return_value={})
                with patch.object(load, "read_counts", side_effect=counts), \
                     patch.object(load.asyncpg, "connect", connect), payload:
                    result = await asyncio.wait_for(load.run(args), timeout=0.5)
                self.assertNotIn(args.password, json.dumps(result))
                self.assertEqual(result["valid"], scenario == "success")
                if scenario == "success":
                    self.assertEqual(result["committed_rows"], 7)
                    self.assertEqual(result["successful_transactions"], 3)
                    self.assertEqual(result["retained_snapshot_delta"], 3)
                    self.assertEqual(result["failed_statements"], 0)
                    self.assertEqual(result["latency_ms"]["unit"], "successful INSERT transaction")
                if scenario == "statement":
                    self.assertEqual(result["failed_statements"], 2)
                    self.assertEqual(result["errors"], {"statement:40P01": 2})
                if scenario == "drain":
                    self.assertEqual(result["errors"]["drain:TimeoutError"], 1)
                if scenario == "target":
                    self.assertFalse(result["target_met"])
                if scenario == "reconcile":
                    self.assertFalse(result["rows_reconciled"])

    def test_invalid_input(self):
        for flag, value in (("--connections", "0"), ("--duration", "nan"), ("--tenants", "-1"),
                            ("--batch-size", "10923"), ("--total-inserts", "0")):
            with self.subTest(flag=flag), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                load.parse_args(["--user", "test", "--password", "fixture", "--db", "test", flag, value])


if __name__ == "__main__":
    unittest.main()
