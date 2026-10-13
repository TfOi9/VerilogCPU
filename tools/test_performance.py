#!/usr/bin/env python3
"""Check performance accounting, failed-run rejection and Pareto boundaries."""

import json
import math
from pathlib import Path
import tempfile
import unittest

from report_performance import functional_input, gates, pareto, require_passed, verify_hashes
from run_performance import (BASELINE, all_configs, case_result, geomean, load_cases,
                             sensitivity_configs)
from run_synthesis import digest


class PerformanceTests(unittest.TestCase):
    def test_geomean_is_not_arithmetic_or_aggregate_ipc(self):
        self.assertAlmostEqual(geomean([0.25, 1.0]), 0.5)
        self.assertNotEqual(geomean([0.25, 1.0]), 0.625)
        for values in ([], [0.0], [-1.0], [math.inf], [math.nan]):
            with self.assertRaises(ValueError):
                geomean(values)

    def test_exact_successful_cycle_record_required(self):
        compare = lambda actual, expected: None if actual == expected else "wrong output"
        self.assertEqual(case_result("0\n", "CPU2026 cycles=15\n", 0, "0\n", 100, compare), 15)
        for stdout, stderr, status in (("1\n", "CPU2026 cycles=15\n", 0),
                                      ("0\n", "CPU2026 cycles=15\n", 1),
                                      ("0\n", "", 0),
                                      ("0\n", "CPU2026 cycles=0\n", 0),
                                      ("0\n", "CPU2026 cycles=101\n", 0),
                                      ("0\n", "CPU2026 cycles=2\nCPU2026 cycles=3\n", 0),
                                      ("0\n", "ERROR failure\nCPU2026 cycles=15\n", 0)):
            with self.subTest(stderr=stderr, status=status), self.assertRaises(ValueError):
                case_result(stdout, stderr, status, "0\n", 100, compare)

    def test_all_cases_and_positive_integer_instruction_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prepare = lambda path, limit, latency: (path.name, "0\n")
            with self.assertRaises(ValueError):
                load_cases(root, 100, 10, prepare)
            for name in ("perf_z", "perf_a"):
                path = root / name
                path.mkdir()
                (path / "metrics.json").write_text('{"dynamic_instructions": 15}')
            (root / "correctness_x").mkdir()
            self.assertEqual([c["name"] for c in load_cases(root, 100, 10, prepare)],
                             ["perf_a", "perf_z"])
            for count in (True, 1.5, 0, -1):
                (root / "perf_a/metrics.json").write_text(json.dumps({"dynamic_instructions": count}))
                with self.assertRaises(ValueError):
                    load_cases(root, 100, 10, prepare)

    def test_sensitivity_changes_one_parameter(self):
        self.assertEqual(len(all_configs()), 18)
        controls = sensitivity_configs()
        self.assertEqual(len(controls), 9)
        self.assertIn(BASELINE, controls)
        for config in controls:
            self.assertLessEqual(sum(a != b for a, b in zip(config, BASELINE)), 1)

    def test_local_smoke_input_uses_archived_image_and_known_answer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "images/accumulate-widths/accumulate.image"
            image.parent.mkdir(parents=True)
            image.write_text("@00000000\n13 00 00 00\n")
            result = {"case": "smoke_accumulate", "log": str(root / "official/smoke_accumulate.log")}
            prepare = lambda *args: self.fail("local smoke must not be read as an official directory")
            data, answer = functional_input(result, root / "testcases", 100, 10, prepare)
            self.assertEqual(data, "CPU2026-OJ 1\n100 10\n@00000000\n13 00 00 00\n")
            self.assertEqual(answer, "5050\n")
            result["case"] = "smoke_unknown"
            with self.assertRaises(ValueError):
                functional_input(result, root / "testcases", 100, 10, prepare)
            result["case"] = "smoke_accumulate"
            image.unlink()
            with self.assertRaises(OSError):
                functional_input(result, root / "testcases", 100, 10, prepare)

    def test_gates_use_unrounded_values_and_joint_eligibility(self):
        stage1 = gates(9000, 0.6, 300)
        self.assertEqual(stage1["highest_eligible_stage"], 1)
        self.assertEqual(gates(36000, 1.0985, 500)["frequency_bonus"], 4)
        self.assertEqual(gates(18000, 0.845, 400)["frequency_bonus"], 2)
        self.assertEqual(gates(9000, 0.5999999999, 500)["highest_eligible_stage"], 0)
        self.assertEqual(gates(9000.0001, 0.6, 500)["highest_eligible_stage"], 0)
        self.assertEqual(gates(9000, 0.6, 299.9999)["highest_eligible_stage"], 0)
        self.assertEqual(gates(9000, 0.1, 500)["frequency_bonus"], 0)

    def test_pareto_strict_dominance_and_frequency_tradeoff(self):
        rows = [{"configuration": "a", "area_um2": 1, "ipc_geomean": 1, "fmax_mhz": 100},
                {"configuration": "b", "area_um2": 2, "ipc_geomean": 0.5, "fmax_mhz": 200},
                {"configuration": "c", "area_um2": 1, "ipc_geomean": 1, "fmax_mhz": 100}]
        self.assertEqual(pareto(rows, ["ipc_geomean"]), ["a", "c"])
        self.assertEqual(pareto(rows, ["ipc_geomean", "fmax_mhz"]), ["a", "b", "c"])

    def test_stale_missing_inputs_and_partial_runs_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.v"
            path.write_text("original")
            hashes = {str(path): digest(path)}
            verify_hashes(hashes)
            path.write_text("changed")
            with self.assertRaises(ValueError):
                verify_hashes(hashes)
            path.unlink()
            with self.assertRaises(ValueError):
                verify_hashes(hashes)
        complete = dict(completed=True, passed=True, sources_unchanged=True)
        require_passed(complete, "test")
        for key in complete:
            with self.assertRaises(ValueError):
                require_passed(dict(complete, **{key: False}), "test")


if __name__ == "__main__":
    unittest.main()
