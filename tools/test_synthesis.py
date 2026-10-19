#!/usr/bin/env python3
"""Exercise synthesis failure gates and parameter projection without ASIC tools."""

import copy
from pathlib import Path
import sys
import tempfile
import time
import unittest

from run_synthesis import ROOT, configured_sources, execute, validate_report


class SynthesisTests(unittest.TestCase):
    def test_parameter_projection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            top = root / "student_top.v"
            text = "module student_top #(\n"
            text += "    parameter FE_WIDTH = 1,\n    parameter BE_WIDTH = 1,\n"
            text += "    parameter PHYS_REGS = 64,\n"
            text += "    parameter PHYS_REG_ADDR_WIDTH = address_width_for_count(PHYS_REGS),\n"
            text += "    parameter ROB_ENTRIES = 32\n) (); endmodule\n"
            top.write_text(text)
            filelist, projected = configured_sources([top], (4, 2, 96, 64), root / "generated")
            self.assertEqual(top.read_text(), text)
            self.assertIn("parameter PHYS_REGS = 96,", projected[0].read_text())
            self.assertIn("address_width_for_count(PHYS_REGS)", projected[0].read_text())
            self.assertEqual(filelist.read_text().strip(), str(projected[0].resolve()))
            top.write_text(text.replace("FE_WIDTH = 1", "FE_WIDTH = compute_width()"))
            with self.assertRaisesRegex(ValueError, "FE_WIDTH"):
                configured_sources([top], (4, 2, 96, 64), root / "rejected")

    def test_process_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "run.log"
            for code in ("print('ERROR: bad mapping')", "print('FAIL invalid parameters')",
                         "raise SystemExit(7)"):
                self.assertFalse(execute([sys.executable, "-c", code], log, 2)["passed"])
            self.assertFalse(execute(["/nonexistent/synthesis-tool"], log, 2)["passed"])
            self.assertTrue(execute([sys.executable, "-c", "print('PASS')"], log, 2)["passed"])

    def test_unconnected_ports_preserve_behavior(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            top = root / "student_top.v"
            text = "module child(input a, output y, output z); assign y=a; assign z=~a; endmodule\n"
            text += "module student_top #(\nparameter FE_WIDTH = 1,\n"
            text += "parameter BE_WIDTH = 1,\nparameter PHYS_REGS = 64,\nparameter ROB_ENTRIES = 32\n) (input a, output y);\n"
            text += "child u(.z(), .a(a), .y(y)); child unused(.a(), .y(), .z()); endmodule\n"
            top.write_text(text)
            _, projected = configured_sources([top], (1, 1, 64, 32), root / "input")
            self.assertEqual(top.read_text(), text)
            bench = root / "bench.v"
            bench.write_text("module bench; reg a; wire y; student_top dut(a,y); initial begin a=0; #1; if(y!==0) $stop; a=1; #1; if(y!==1) $stop; $display(\"PASS\"); $finish; end endmodule\n")
            for index, source in enumerate((top, projected[0])):
                binary = root / (str(index) + ".vvp")
                result = execute(["iverilog", "-g2005", "-s", "bench", "-o", str(binary),
                                  str(source), str(bench)], root / "compile.log", 5)
                self.assertTrue(result["passed"], result)
                result = execute(["vvp", "-N", str(binary)], root / "simulate.log", 5)
                self.assertTrue(result["passed"], result)
                self.assertIn("PASS", (root / "simulate.log").read_text())

    def test_forwarding_byte_equivalence(self):
        text = (ROOT / "rtl/rv32_load_store_queue.v").read_text()
        functions = []
        for name in ("align_store_word", "unalign_word", "unalign_mask"):
            width = "3:0" if name == "unalign_mask" else "31:0"
            start = text.index("    function [" + width + "] " + name + ";")
            end = text.index("endfunction", start)
            functions.append(text[start:end + len("endfunction")])
        out = ROOT / "build/synthesis-unit"
        out.mkdir(parents=True, exist_ok=True)
        source = out / "forwarding_equivalence.v"
        source.write_text("module proof(input [31:0] value, input [3:0] mask, "
                          "input [1:0] offset, output equal);\n" + "\n".join(functions) +
                          "\nassign equal = (align_store_word(value, offset) == (value << (offset*8))) && "
                          "(unalign_word(value, offset) == (value >> (offset*8))) && "
                          "(unalign_mask(mask, offset) == (mask >> offset));\nendmodule\n")
        script = out / "forwarding_equivalence.ys"
        script.write_text("read_verilog " + str(source) + "; hierarchy -top proof; proc; opt; "
                          "sat -verify -prove equal 1 -show-inputs\n")
        result = execute([str(ROOT / ".deps/yosys/bin/yosys"), "-Q", "-T", "-s", str(script)],
                         out / "forwarding_equivalence.log", 10)
        self.assertTrue(result["passed"], result)
        self.assertIn("SUCCESS", (out / "forwarding_equivalence.log").read_text())

    def test_timeout_kills_children(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "child-finished"
            child = "import time; from pathlib import Path; time.sleep(2); Path({!r}).touch()".format(str(marker))
            parent = "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', {!r}]); time.sleep(10)".format(child)
            result = execute([sys.executable, "-c", parent], root / "timeout.log", 0.3)
            self.assertFalse(result["passed"])
            self.assertIn("timeout", result["error"])
            time.sleep(2.1)
            self.assertFalse(marker.exists(), "timed-out child tool survived")

    def test_report_gates(self):
        report = {"mode": "opt", "sram_model": {"estimated": True}, "area": {
            "area_um2": 30.0, "logic_area_um2": 20.0, "combinational_area_um2": 12.0,
            "sequential_area_um2": 8.0, "sram_area_um2": 10.0,
            "sram_instances": [{"area_um2": 10.0}]}, "timing": {
            "timing_analyzed": True, "clock_period_ns": 2.0, "minimum_period_ns": 5.0,
            "estimated_fmax_mhz": 200.0, "worst_setup_slack_ns": -3.0,
            "critical_paths": [{"startpoint": "a", "endpoint": "b"}]}}
        validate_report(report, "opt", 2.0)
        for section, key, value in (("area", "area_um2", 20.0),
                                    ("area", "sram_instances", []),
                                    ("timing", "estimated_fmax_mhz", None),
                                    ("timing", "worst_setup_slack_ns", float("nan")),
                                    ("timing", "critical_paths", [])):
            invalid = copy.deepcopy(report)
            invalid[section][key] = value
            with self.assertRaises(ValueError):
                validate_report(invalid, "opt", 2.0)
        with self.assertRaises(ValueError):
            validate_report(report, "diagnose", 2.0)


if __name__ == "__main__":
    unittest.main()
