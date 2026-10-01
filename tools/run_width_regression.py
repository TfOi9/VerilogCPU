#!/usr/bin/env python3
"""Run bounded official and smoke regressions with isolated width builds."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", type=Path, default=Path("../RISC-V-CPU-2026"))
    parser.add_argument("--testcases", type=Path, default=Path("../RISC-V-CPU-2026-Testcases"))
    parser.add_argument("--filelist", type=Path, default=Path("verilog/filelist.f"))
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--report", type=Path, default=Path("reports/width-regression.json"))
    parser.add_argument("--fe-width", type=int, choices=(1, 2, 4))
    parser.add_argument("--be-width", type=int, choices=(1, 2, 4))
    parser.add_argument("--sim", type=Path)
    parser.add_argument("--mode", choices=("smoke", "test", "all"), default="all")
    parser.add_argument("--case")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--appimage", default="")
    parser.add_argument("--max-cycles", type=int, default=30000000)
    parser.add_argument("--latency", type=int, default=10)
    args = parser.parse_args()
    if (args.fe_width is None) != (args.be_width is None):
        parser.error("specify both FE and BE widths")
    if args.sim and args.fe_width is None:
        parser.error("--sim requires a single width configuration")
    sys.path.insert(0, str((args.framework / "scripts").resolve()))
    from oj_io import prepare_case, compare_output

    cases = []
    if args.mode in ("test", "all"):
        directories = sorted(args.testcases.glob("correctness_*"))
        directories += [args.testcases / name for name in ("perf_multiply", "perf_vvadd")]
        if args.case:
            directories = [args.testcases / args.case]
        for case in directories:
            data, answer = prepare_case(case, args.max_cycles, args.latency)
            cases.append((case.name, data, answer))
        if not directories:
            parser.error("no correctness testcases found")
    if args.mode in ("smoke", "all"):
        for name, result in (("accumulate", 5050), ("core_ooo", 42)):
            out = args.build_root / "images" / (name + "-widths")
            subprocess.run([sys.executable, "tools/make_image.py", "tests/programs/" + name + ".c",
                            "--arch", "rv32im", "--out-dir", str(out)], check=True, timeout=120)
            image = (out / (name + ".image")).read_text()
            data = "CPU2026-OJ 1\n{} {}\n{}\n".format(args.max_cycles, args.latency, image.rstrip())
            cases.append(("smoke_" + name, data, str(result) + "\n"))

    configurations = [(args.fe_width, args.be_width)] if args.fe_width else [
        (fe, be) for fe in (1, 2, 4) for be in (1, 2, 4)]
    records = []
    args.report.parent.mkdir(parents=True, exist_ok=True)
    testcase_revision = subprocess.run(["git", "-C", str(args.testcases), "rev-parse", "HEAD"],
                                       capture_output=True, text=True, check=True).stdout.strip()
    digest = hashlib.sha256()
    for line in args.filelist.read_text().splitlines():
        if line.strip():
            source = args.filelist.parent / line.strip()
            digest.update(source.read_bytes())
    metadata = {"rtl_sha256": digest.hexdigest(), "testcases_revision": testcase_revision,
                "phys_regs": 64, "rob_entries": 32, "latency": args.latency,
                "max_cycles": args.max_cycles, "wall_timeout_seconds": 1800,
                "watchdog_cycles": 100000, "results": records}

    def save():
        args.report.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    for fe, be in configurations:
        out = args.build_root / "official-{}x{}".format(fe, be)
        out.mkdir(parents=True, exist_ok=True)
        simulator = (args.sim or out / "sim").resolve()
        if not args.sim:
            print("BUILD FE={} BE={}".format(fe, be), flush=True)
            command = [sys.executable, "tools/build_configured.py", "--framework", str(args.framework),
                       "--filelist", str(args.filelist), "--out", str(out),
                       "--fe-width", str(fe), "--be-width", str(be), "--jobs", str(args.jobs),
                       "--appimage", args.appimage]
            with (out / "build.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
        for name, data, answer in cases:
            error = None
            stdout = stderr = ""
            try:
                process = subprocess.run([str(simulator)], input=data, capture_output=True,
                                         text=True, timeout=1800)
                stdout, stderr = process.stdout, process.stderr
                error = compare_output(stdout, answer)
                if process.returncode:
                    error = "simulator status {}: {}".format(process.returncode, stderr.strip())
            except subprocess.TimeoutExpired as timeout:
                stdout = (timeout.stdout or b"").decode(errors="replace")
                stderr = (timeout.stderr or b"").decode(errors="replace")
                error = "wall timeout after 1800 seconds"
            log_path = out / (name + ".log")
            log_path.write_text(stdout + stderr, encoding="utf-8")
            match = re.search(r"CPU2026 cycles=(\d+)", stderr)
            records.append({"fe_width": fe, "be_width": be, "case": name,
                            "passed": error is None, "cycles": int(match.group(1)) if match else None,
                            "expected": int(answer.strip()), "log": str(log_path), "error": error})
            save()
            print("{} FE={} BE={} {} cycles={}{}".format(
                "FAIL" if error else "PASS", fe, be, name, records[-1]["cycles"],
                " " + error if error else ""), flush=True)
    failed = sum(not row["passed"] for row in records)
    print("Results: {} passed, {} failed; {}".format(len(records) - failed, failed, args.report))
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
