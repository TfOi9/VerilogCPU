#!/usr/bin/env python3
"""Measure every official performance case with bounded, fresh simulator builds."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time

from run_parameter_matrix import (PHYSICAL_COUNTS, REPRESENTATIVES, ROB_COUNTS,
                                  WIDTHS, config_name, configured_options, parameters)
from run_synthesis import digest, execute


ROOT = Path(__file__).resolve().parents[1]
BASELINE = (2, 2, 64, 32)
DEFAULT = (1, 1, 64, 32)
PARAMETER_VALUES = (WIDTHS, WIDTHS, PHYSICAL_COUNTS, ROB_COUNTS)
CYCLES = re.compile(r"^CPU2026 cycles=(\d+)$", re.MULTILINE)


def sensitivity_configs():
    configs = {BASELINE}
    for index, values in enumerate(PARAMETER_VALUES):
        for value in values:
            current = list(BASELINE)
            current[index] = value
            configs.add(tuple(current))
    return sorted(configs)


def all_configs():
    return sorted(set(REPRESENTATIVES) | set(sensitivity_configs()) | {DEFAULT})


def geomean(values):
    if not values or any(not math.isfinite(value) or value <= 0 for value in values):
        raise ValueError("geometric mean requires finite positive values and a nonempty set")
    return math.exp(math.fsum(math.log(value) for value in values) / len(values))


def case_result(stdout, stderr, returncode, answer, limit, compare_output):
    if returncode != 0:
        raise ValueError("simulator returned {}".format(returncode))
    error = compare_output(stdout, answer)
    if error:
        raise ValueError(error)
    if re.search(r"(?mi)^(?:ERROR|FAIL|%Error|Error):?\b", stderr):
        raise ValueError("simulator reported an error")
    matches = CYCLES.findall(stderr)
    if len(matches) != 1 or not 0 < int(matches[0]) <= limit:
        raise ValueError("missing, duplicate or invalid cycle count")
    return int(matches[0])


def load_cases(testcases, limit, latency, prepare_case):
    cases = []
    for path in sorted(testcases.glob("perf_*")):
        if not path.is_dir():
            continue
        instructions = json.loads((path / "metrics.json").read_text())["dynamic_instructions"]
        if type(instructions) is not int or instructions <= 0:
            raise ValueError("invalid dynamic instruction count in " + str(path))
        data, answer = prepare_case(path, limit, latency)
        cases.append({"name": path.name, "dynamic_instructions": instructions,
                      "data": data, "answer": answer, "path": path})
    if not cases:
        raise ValueError("no official perf_* cases found")
    return cases


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", type=Path, default=Path("../RISC-V-CPU-2026"))
    parser.add_argument("--testcases", type=Path, default=Path("../RISC-V-CPU-2026-Testcases"))
    parser.add_argument("--filelist", type=Path, default=Path("verilog/filelist.f"))
    parser.add_argument("--build-root", type=Path, default=Path("build/perf"))
    parser.add_argument("--report", type=Path, default=Path("reports/performance.json"))
    parser.add_argument("--config", help="focused FE,BE,PHYS,ROB configuration")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--config-jobs", type=int, default=2)
    parser.add_argument("--appimage", default="")
    parser.add_argument("--max-cycles", type=int, default=30000000)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--build-timeout", type=int, default=600)
    parser.add_argument("--case-timeout", type=int, default=1800)
    args = parser.parse_args()
    if min(args.jobs, args.config_jobs, args.max_cycles, args.latency,
           args.build_timeout, args.case_timeout) < 1:
        parser.error("jobs, timeouts, latency and cycle limit must be positive")
    configs = all_configs()
    if args.config:
        current = tuple(int(value) for value in args.config.split(","))
        if len(current) != 4 or any(value not in values for value, values in
                                    zip(current, PARAMETER_VALUES)):
            parser.error("config is outside the supported parameter matrix")
        configs = [current]
    framework = args.framework.resolve()
    testcases = args.testcases.resolve()
    sys.path.insert(0, str(framework / "scripts"))
    from build import read_sources
    from fakeram import RAM_SOURCE
    from oj_io import compare_output, prepare_case

    sources = read_sources(args.filelist)
    headers = sorted({header for source in sources for header in source.parent.glob("*.vh")})
    hardware = sources + headers + [RAM_SOURCE]
    dependencies = set(hardware + [args.filelist.resolve(), ROOT / "Makefile",
                       Path(__file__).resolve(), ROOT / "tools/build_configured.py",
                       ROOT / "tools/run_parameter_matrix.py", ROOT / "tools/run_synthesis.py",
                       framework / "scripts/sim.cpp"])
    dependencies.update((framework / "scripts").glob("*.py"))
    dependencies.update(Path(shutil.which(tool)).resolve() for tool in
                        ("verilator", "g++", "ar", "make") if shutil.which(tool))
    cases = load_cases(testcases, args.max_cycles, args.latency, prepare_case)
    for case in cases:
        dependencies.update(case["path"] / name for name in
                            ("metrics.json", "program.data", "expected.txt"))
    hashes = {str(path): digest(path) for path in sorted(dependencies)}
    metadata = {"schema_version": 1, "started_at": datetime.now(timezone.utc).isoformat(),
                "framework": str(framework), "testcases": str(testcases),
                "testcases_revision": subprocess.check_output(
                    ["git", "-C", str(testcases), "rev-parse", "HEAD"], text=True).strip(),
                "filelist": str(args.filelist.resolve()), "source_sha256": hashes,
                "hardware_sha256": {str(path): digest(path) for path in hardware},
                "configurations": [parameters(c) for c in configs],
                "representatives": [parameters(c) for c in REPRESENTATIVES],
                "sensitivity_baseline": parameters(BASELINE),
                "cases": [{"name": c["name"], "dynamic_instructions": c["dynamic_instructions"]}
                          for c in cases],
                "max_cycles": args.max_cycles, "latency": args.latency,
                "watchdog_cycles": 100000, "build_timeout_seconds": args.build_timeout,
                "case_timeout_seconds": args.case_timeout,
                "completed": False, "passed": False, "results": []}
    args.report = args.report.resolve()
    out_root = args.build_root.resolve()
    for case in cases:
        out = out_root / "inputs" / case["name"]
        out.parent.mkdir(parents=True, exist_ok=True)
        out.with_suffix(".in").write_text(case["data"])
        out.with_suffix(".ans").write_text(case["answer"])
    guard = threading.Lock()
    write_json(args.report, metadata)

    def run_config(config):
        out = out_root / config_name(config)
        command = [sys.executable, str(ROOT / "tools/build_configured.py"),
                   "--framework", str(framework), "--filelist", str(args.filelist.resolve()),
                   "--out", str(out), "--jobs", str(args.jobs), "--appimage", args.appimage]
        command += configured_options(config)
        build = execute(command, out / "build.log", args.build_timeout)
        simulator = out / "sim"
        row = dict(parameters(config), build=build, cases=[], passed=False)
        if build["passed"] and simulator.is_file():
            row["simulator"] = {"path": str(simulator), "sha256": digest(simulator)}
            for case in cases:
                started = time.monotonic()
                result = {"name": case["name"], "dynamic_instructions": case["dynamic_instructions"],
                          "passed": False, "cycles": None, "ipc": None, "error": None,
                          "input_sha256": hashlib.sha256(case["data"].encode()).hexdigest()}
                log = out / case["name"]
                result.update(stdout_path=str(log.with_suffix(".stdout")),
                              stderr_path=str(log.with_suffix(".stderr")))
                stdout, stderr = "", ""
                try:
                    process = subprocess.run([str(simulator)], input=case["data"], text=True,
                                             capture_output=True, timeout=args.case_timeout)
                    stdout, stderr = process.stdout, process.stderr
                    result["returncode"] = process.returncode
                    cycles = case_result(stdout, stderr, process.returncode, case["answer"],
                                         args.max_cycles, compare_output)
                    result.update(passed=True, cycles=cycles, ipc=case["dynamic_instructions"] / cycles)
                except subprocess.TimeoutExpired as error:
                    stdout = (error.stdout or b"").decode(errors="replace")
                    stderr = (error.stderr or b"").decode(errors="replace")
                    result["error"] = "wall timeout after {} seconds".format(args.case_timeout)
                except (OSError, ValueError) as error:
                    result["error"] = str(error)
                log.with_suffix(".stdout").write_text(stdout)
                log.with_suffix(".stderr").write_text(stderr)
                result["elapsed_seconds"] = round(time.monotonic() - started, 3)
                row["cases"].append(result)
                print("{} {} {} cycles={} IPC={}".format(
                    "PASS" if result["passed"] else "FAIL", config_name(config), case["name"],
                    result["cycles"], result["ipc"]), flush=True)
            row["passed"] = len(row["cases"]) == len(cases) and all(c["passed"] for c in row["cases"])
            if row["passed"]:
                row["ipc_geomean"] = geomean([c["ipc"] for c in row["cases"]])
        else:
            row["error"] = build.get("error") or "missing simulator binary"
        with guard:
            metadata["results"].append(row)
            write_json(args.report, metadata)
        print("{} {} GEOMEAN={}".format("PASS" if row["passed"] else "FAIL",
              config_name(config), row.get("ipc_geomean")), flush=True)

    with ThreadPoolExecutor(max_workers=min(args.config_jobs, len(configs))) as pool:
        list(pool.map(run_config, configs))
    metadata["results"].sort(key=lambda r: tuple(r[key] for key in parameters(BASELINE)))
    metadata["sources_unchanged"] = all(Path(path).is_file() and digest(Path(path)) == value
                                        for path, value in hashes.items())
    metadata["completed"] = len(metadata["results"]) == len(configs)
    metadata["passed"] = metadata["completed"] and metadata["sources_unchanged"] and all(
        row["passed"] for row in metadata["results"])
    metadata["finished_at"] = datetime.now(timezone.utc).isoformat()
    write_json(args.report, metadata)
    print("Performance report: " + str(args.report))
    return 0 if metadata["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError) as failure:
        print("error: " + str(failure), file=sys.stderr)
        sys.exit(2)
