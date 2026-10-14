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
    parser.add_argument("--phys-regs", type=int, default=64)
    parser.add_argument("--rob-entries", type=int, default=32)
    parser.add_argument("--sim", type=Path)
    parser.add_argument("--mode", choices=("smoke", "test", "all"), default="all")
    parser.add_argument("--case")
    parser.add_argument("--all-performance", action="store_true",
                        help="run all six official performance cases as functional checks")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--appimage", default="")
    parser.add_argument("--max-cycles", type=int, default=30000000)
    parser.add_argument("--latency", type=int, default=10)
    args = parser.parse_args()
    if (args.fe_width is None) != (args.be_width is None):
        parser.error("specify both FE and BE widths")
    if args.sim and args.fe_width is None:
        parser.error("--sim requires a single width configuration")
    if args.phys_regs < 33 or args.rob_entries < 2 or args.rob_entries & (args.rob_entries - 1):
        parser.error("invalid physical register count or ROB capacity")
    if args.jobs < 1 or args.max_cycles < 1 or args.latency < 1:
        parser.error("jobs, cycle limit and latency must be positive")
    sys.path.insert(0, str((args.framework / "scripts").resolve()))
    from oj_io import prepare_case, compare_output
    from build import read_sources

    cases = []
    if args.mode in ("test", "all"):
        directories = sorted(args.testcases.glob("correctness_*"))
        performance = ("perf_median", "perf_multiply", "perf_qsort", "perf_rsort",
                       "perf_towers", "perf_vvadd") if args.all_performance else ("perf_multiply", "perf_vvadd")
        directories += [args.testcases / name for name in performance]
        if args.case:
            directories = [args.testcases / args.case]
        for case in directories:
            data, answer = prepare_case(case, args.max_cycles, args.latency)
            cases.append((case.name, data, answer, case / "program.data"))
        if not directories:
            parser.error("no correctness testcases found")
    if args.mode in ("smoke", "all"):
        for name, result in (("accumulate", 5050), ("core_ooo", 42)):
            out = args.build_root / "images" / (name + "-widths")
            subprocess.run([sys.executable, "tools/make_image.py", "tests/programs/" + name + ".c",
                            "--arch", "rv32im", "--out-dir", str(out)], check=True, timeout=120)
            image = (out / (name + ".image")).read_text()
            data = "CPU2026-OJ 1\n{} {}\n{}\n".format(args.max_cycles, args.latency, image.rstrip())
            cases.append(("smoke_" + name, data, str(result) + "\n", out / (name + ".image")))

    configurations = [(args.fe_width, args.be_width)] if args.fe_width else [
        (fe, be) for fe in (1, 2, 4) for be in (1, 2, 4)]
    records = []
    args.report.parent.mkdir(parents=True, exist_ok=True)
    testcase_revision = subprocess.run(["git", "-C", str(args.testcases), "rev-parse", "HEAD"],
                                       capture_output=True, text=True, check=True).stdout.strip()
    digest = hashlib.sha256()
    sources = read_sources(args.filelist)
    headers = sorted({header for source in sources for header in source.parent.glob("*.vh")})
    for source in sources + headers:
        digest.update(source.name.encode() + b"\0" + source.read_bytes())
    metadata = {"rtl_sha256": digest.hexdigest(), "testcases_revision": testcase_revision,
                "phys_regs": args.phys_regs, "rob_entries": args.rob_entries, "latency": args.latency,
                "max_cycles": args.max_cycles, "wall_timeout_seconds": 1800,
                "watchdog_cycles": 100000, "mode": args.mode, "case_filter": args.case,
                "all_performance": args.all_performance,
                "completed": False, "results": records}

    def save():
        args.report.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    for fe, be in configurations:
        out = args.build_root / "official-{}x{}".format(fe, be)
        if (args.phys_regs, args.rob_entries) != (64, 32):
            out = out.with_name(out.name + "-p{}-r{}".format(args.phys_regs, args.rob_entries))
        out.mkdir(parents=True, exist_ok=True)
        simulator = (args.sim or out / "sim").resolve()
        if not args.sim:
            print("BUILD FE={} BE={}".format(fe, be), flush=True)
            command = [sys.executable, "tools/build_configured.py", "--framework", str(args.framework),
                       "--filelist", str(args.filelist), "--out", str(out),
                       "--fe-width", str(fe), "--be-width", str(be), "--jobs", str(args.jobs),
                       "--phys-regs", str(args.phys_regs), "--rob-entries", str(args.rob_entries),
                       "--appimage", args.appimage]
            with (out / "build.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
        save()
        for name, data, answer, image in cases:
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
            if error is None and (not match or int(match.group(1)) < 1):
                error = "missing positive simulator cycle count"
            records.append({"fe_width": fe, "be_width": be, "case": name,
                            "phys_regs": args.phys_regs, "rob_entries": args.rob_entries,
                            "passed": error is None, "cycles": int(match.group(1)) if match else None,
                            "expected": int(answer.strip()), "log": str(log_path), "error": error,
                            "input_sha256": hashlib.sha256(data.encode()).hexdigest()})
            if error:
                log_path.with_suffix(".in").write_text(data, encoding="utf-8")
                records[-1]["reproduce"] = ["timeout", "1800", str(simulator), str(image.resolve()),
                                             answer.strip(), str(args.max_cycles), str(args.latency),
                                             str(log_path.with_suffix(".vcd").resolve())]
            save()
            print("{} FE={} BE={} {} cycles={}{}".format(
                "FAIL" if error else "PASS", fe, be, name, records[-1]["cycles"],
                " " + error if error else ""), flush=True)
    failed = sum(not row["passed"] for row in records)
    metadata["completed"] = True
    metadata["passed"] = failed == 0
    save()
    print("Results: {} passed, {} failed; {}".format(len(records) - failed, failed, args.report))
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
