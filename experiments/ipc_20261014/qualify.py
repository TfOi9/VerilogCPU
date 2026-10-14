#!/usr/bin/env python3
"""Run two small throughput probes and one configuration of core correctness checks."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/ipc-20261014/qualification"
sys.path.insert(0, str(ROOT / "tools"))
from generate_core_vectors import branch, execute, immediate, store


def run(command, name, seconds=30):
    full = ["timeout", "-k", "5", str(seconds), *map(str, command)]
    result = subprocess.run(full, text=True, capture_output=True)
    (OUT / (name + ".log")).write_text(result.stdout + result.stderr)
    row = {"name": name, "command": full, "returncode": result.returncode,
           "passed": result.returncode == 0,
           "log_sha256": hashlib.sha256((result.stdout + result.stderr).encode()).hexdigest()}
    rows.append(row)
    (OUT / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
    if result.returncode or re.search(r"(?m)^(FAIL|ERROR|%Error)\b", result.stdout + result.stderr):
        row["passed"] = False
        (OUT / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        raise RuntimeError("failed: " + name)
    print("PASS", name, flush=True)
    return result.stdout + result.stderr, row


def require(condition, row, message):
    if not condition:
        row.update(passed=False, error=message)
        (OUT / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        raise RuntimeError(message)


OUT.mkdir(parents=True, exist_ok=True)
if (OUT / "results.json").exists():
    raise SystemExit("qualification output already exists")
rows = []
for kind in ("load", "store"):
    words = [0x000100b7, immediate(2, 0, 100), immediate(3, 0, 85), store(3, 1, 0)]
    loop = len(words)*4
    for index in range(32):
        words.append(immediate(8 + index % 8, 1, 0, 2, 0x03) if kind == "load" else store(3, 1, 0))
    words.append(immediate(2, 2, -1))
    words.append(branch(2, 0, loop-len(words)*4, 1))
    words += [immediate(10, 1, 0, 2, 0x03), 0x80000fb7, store(10, 31, 0)]
    reference, expected = execute(words)
    image = OUT / (kind + ".data")
    image.write_text("@00000000\n" + "\n".join(" ".join("{:02x}".format(b)
        for b in word.to_bytes(4, "little")) for word in words) + "\n")
    for label, relative in (
        ("baseline", "build/cache-20261014-v2/baseline/sim"),
        ("loads", "build/ipc-20261014/load-pilot-v2/baseline/sim"),
        ("stores", "build/ipc-20261014/store-pilot/baseline/sim"),
        ("combined", "build/ipc-20261014/combined-pilot/baseline/sim"),
    ):
        sim = ROOT / relative
        output, row = run([sim, image, expected, 100000, 10], label + "-hot-" + kind)
        match = re.search(r"^PASS cycles=(\d+) result=(\d+) expected=(\d+)$", output, re.MULTILINE)
        require(match and int(match[2]) == expected and int(match[3]) == expected,
                row, "invalid microbenchmark result")
        row.update(cycles=int(match[1]), instructions=len(reference),
                   sim_sha256=hashlib.sha256(sim.read_bytes()).hexdigest(),
                   image_sha256=hashlib.sha256(image.read_bytes()).hexdigest())

run([sys.executable, "-B", ROOT / "tools/generate_core_vectors.py",
     "--out", OUT / "core", "--seed", "0x2401"], "generate-core")
sources = [ROOT / "rtl" / Path(line).name for line in
           (ROOT / "verilog/filelist.f").read_text().splitlines() if line.strip()]
sources = [p for p in sources if not p.name.startswith("rv32_l1_") and p.name != "student_top.v"]
common = ["verilator", "--binary", "--timing", "--assert", "--language", "1364-2005",
          "-Wall", "-Wno-fatal", "-DRV32_TEST_WATCHDOG", "-GFE_WIDTH=2", "-GBE_WIDTH=2",
          "-I" + str(ROOT / "rtl"), "-j", "1"]
for top, label in (("rv32_cpu_core_width_tb", "core"), ("rv32_cpu_core_alignment_tb", "alignment")):
    obj = OUT / (label + "-obj")
    run([*common, "--trace", "--top-module", top, "--Mdir", obj, "-o", "sim",
         *sources, ROOT / "tb" / (top + ".v")], label + "-build", 180)
    if label == "core":
        output, row = run([obj / "sim", "+PROGRAM=" + str(OUT / "core.words"),
            "+TRACE=" + str(OUT / "core.trace"),
            "+EXPECTED=" + (OUT / "core.result").read_text().strip(), "+SEED=9217"], "retirement-differential")
        require("PASS core FE=2 BE=2" in output, row, "missing retirement PASS")
    else:
        for case in range(5):
            output, row = run([obj / "sim", "+CASE=" + str(case)], "alignment-" + str(case))
            require("PASS" in output, row, "missing exception PASS")
(OUT / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
