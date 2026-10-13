#!/usr/bin/env python3
"""Test matrix coverage and fail-closed tool result handling."""

import itertools
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from run_parameter_matrix import (PHYSICAL_COUNTS, REPRESENTATIVES, ROB_COUNTS,
                                  WIDTHS, execute)


class ParameterMatrixTest(unittest.TestCase):
    def test_representative_coverage(self):
        self.assertEqual(len(REPRESENTATIVES), 9)
        self.assertEqual({(fe, be) for fe, be, _, _ in REPRESENTATIVES},
                         set(itertools.product(WIDTHS, repeat=2)))
        self.assertEqual({(phys, rob) for _, _, phys, rob in REPRESENTATIVES},
                         set(itertools.product(PHYSICAL_COUNTS, ROB_COUNTS)))
        self.assertTrue(all(config in set(itertools.product(
            WIDTHS, WIDTHS, PHYSICAL_COUNTS, ROB_COUNTS)) for config in REPRESENTATIVES))

    def test_tool_failure_records(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "tool.log"
            for text in ("ERROR parameter mismatch", "FAIL retirement mismatch", "%Error bad width"):
                result = execute([sys.executable, "-c", "print({!r})".format(text)], log, 5)
                self.assertFalse(result["passed"])
                self.assertEqual(result["returncode"], 0)
                self.assertIn(text, log.read_text())
            result = execute([sys.executable, "-c", "raise SystemExit(2)"], log, 5)
            self.assertFalse(result["passed"])
            self.assertEqual(result["returncode"], 2)
            result = execute([sys.executable, "-c", "import time; time.sleep(5)"], log, 0.05)
            self.assertFalse(result["passed"])
            self.assertIn("wall timeout", result["error"])
            result = execute([str(Path(directory) / "missing-tool")], log, 5)
            self.assertFalse(result["passed"])
            result = execute([sys.executable, "-c", "print('PASS tool')"], log, 5)
            self.assertTrue(result["passed"])

    def test_build_rejects_invalid_capacities(self):
        base = [sys.executable, "tools/build_configured.py", "--framework", "/missing",
                "--filelist", "/missing", "--out", "/missing", "--fe-width", "4", "--be-width", "4"]
        for options, message in ((["--phys-regs", "32"], "at least 33"),
                                 (["--rob-entries", "24"], "power of two"),
                                 (["--rob-entries", "2"], "power of two")):
            result = subprocess.run(base + options, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
