#!/usr/bin/env python3
"""Check all capacity/width combinations and regress nine representatives."""

import argparse
import hashlib
import itertools
import json
import re
import shlex
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path


WIDTHS = (1, 2, 4)
PHYSICAL_COUNTS = (48, 64, 96)
ROB_COUNTS = (16, 32, 64)
REPRESENTATIVES = (
    (1, 1, 48, 16), (1, 2, 64, 32), (1, 4, 96, 64),
    (2, 1, 64, 64), (2, 2, 96, 16), (2, 4, 48, 32),
    (4, 1, 96, 32), (4, 2, 48, 64), (4, 4, 64, 16),
)
SEEDS = (0x2401, 0x2402, 0x2403)


def parameters(config):
    return dict(zip(("FE_WIDTH", "BE_WIDTH", "PHYS_REGS", "ROB_ENTRIES"), config))


def config_name(config):
    return "{}x{}-p{}-r{}".format(*config)


def configured_options(config):
    return [item for option, value in zip(
        ("--fe-width", "--be-width", "--phys-regs", "--rob-entries"), config)
        for item in (option, str(value))]


def execute(command, log, seconds):
    log.parent.mkdir(parents=True, exist_ok=True)
    error = None
    status = None
    with log.open("w") as output:
        try:
            process = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                     timeout=seconds)
            status = process.returncode
            if status:
                error = "process status {}".format(status)
        except subprocess.TimeoutExpired:
            error = "wall timeout after {} seconds".format(seconds)
        except OSError as failure:
            error = str(failure)
    text = log.read_text(errors="replace")
    if error is None and re.search(r"(^|\n)(ERROR|FAIL|%Error)\b", text):
        error = "tool reported an error; see log"
    return {"passed": error is None, "returncode": status, "error": error,
            "log": str(log), "command": command, "timeout_seconds": seconds}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", type=Path, default=Path("../RISC-V-CPU-2026"))
    parser.add_argument("--testcases", type=Path, default=Path("../RISC-V-CPU-2026-Testcases"))
    parser.add_argument("--filelist", type=Path, default=Path("verilog/filelist.f"))
    parser.add_argument("--build-root", type=Path, default=Path("build/matrix"))
    parser.add_argument("--report", type=Path, default=Path("reports/parameter-matrix.json"))
    parser.add_argument("--phase", choices=("all", "lint", "functional"), default="all")
    parser.add_argument("--config", help="focused FE,BE,PHYS,ROB configuration")
    parser.add_argument("--all-performance", action="store_true",
                        help="include all six official performance cases in every functional run")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--lint-jobs", type=int, default=2)
    parser.add_argument("--appimage", default="")
    parser.add_argument("--max-cycles", type=int, default=30000000)
    parser.add_argument("--latency", type=int, default=10)
    args = parser.parse_args()
    if args.jobs < 1 or args.lint_jobs < 1 or args.max_cycles < 1 or args.latency < 1:
        parser.error("jobs, cycle limit and latency must be positive")
    matrix = list(itertools.product(WIDTHS, WIDTHS, PHYSICAL_COUNTS, ROB_COUNTS))
    representatives = list(REPRESENTATIVES)
    if args.config:
        try:
            config = tuple(int(value) for value in args.config.split(","))
        except ValueError:
            parser.error("config must contain four integers")
        if config not in matrix:
            parser.error("config is outside the supported matrix")
        matrix = representatives = [config]

    sys.path.insert(0, str((args.framework / "scripts").resolve()))
    from build import read_sources
    from fakeram import RAM_SOURCE

    sources = read_sources(args.filelist)
    core_sources = [path for path in sources if path.name not in (
        "student_top.v", "rv32_l1_instruction_cache.v", "rv32_l1_data_cache.v",
        "rv32_l1_cache_axi_bridge.v")]
    headers = sorted({header for source in sources for header in source.parent.glob("*.vh")})
    dependencies = sources + headers + [RAM_SOURCE, args.framework / "scripts/sim.cpp",
                                       Path("tb/rv32_cpu_core_width_tb.v")]
    dependencies += sorted(Path("tools").glob("*.py"))
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in dependencies}
    metadata = {"schema_version": 1, "started_at": datetime.now(timezone.utc).isoformat(),
                "phase": args.phase, "focused_config": args.config,
                "all_performance": args.all_performance,
                "testcases_revision": subprocess.check_output(
                    ["git", "-C", str(args.testcases), "rev-parse", "HEAD"], text=True).strip(),
                "source_sha256": hashes, "max_cycles": args.max_cycles,
                "latency": args.latency, "watchdog_cycles": 100000,
                "matrix": [parameters(config) for config in matrix],
                "representatives": [parameters(config) for config in representatives],
                "seeds": list(SEEDS), "completed": False, "passed": False,
                "checks": [], "functional": []}
    args.report.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.report.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    report_lock = threading.Lock()

    def record(config, stage, command, log, seconds):
        row = execute(command, log, seconds)
        row.update(parameters(config) if config else {})
        row["stage"] = stage
        with report_lock:
            metadata["checks"].append(row)
            save()
            print("{} {} {}{}".format("PASS" if row["passed"] else "FAIL", stage,
                                       config_name(config) if config else "",
                                       " " + row["error"] if row["error"] else ""), flush=True)
        return row["passed"]

    save()
    source_args = [str(path) for path in sources]
    if args.phase in ("all", "lint"):
        def lint_config(config):
            out = args.build_root / config_name(config)
            overrides = parameters(config)
            binary = out / "elaborated.vvp"
            command = ["iverilog", "-g2005", "-D", "SYNTHESIS", "-I", "rtl",
                       "-s", "student_top", "-o", str(binary)]
            command += ["-Pstudent_top.{}={}".format(key, value) for key, value in overrides.items()]
            command += [str(RAM_SOURCE)] + source_args
            if not record(config, "iverilog-2005", command, out / "iverilog.log", 60):
                return
            if not record(config, "parameter-startup", ["vvp", "-N", str(binary)],
                          out / "startup.log", 30):
                return
            command = ["verilator", "--lint-only", "--language", "1364-2005",
                       "+1800-2012ext+sv", "-Wall", "-Wno-TIMESCALEMOD", "-Wno-BLKSEQ",
                       "-Wno-DECLFILENAME", "-Wno-PINCONNECTEMPTY", "-Wno-UNUSEDSIGNAL",
                       "--top-module", "student_top", "-Irtl"]
            command += ["-G{}={}".format(key, value) for key, value in overrides.items()]
            command += [str(RAM_SOURCE)] + source_args
            record(config, "verilator", command, out / "verilator.log", 60)
            script = "read_verilog -lib -D SYNTHESIS {}; read_verilog -D SYNTHESIS -I rtl {}; ".format(
                shlex.quote(str(RAM_SOURCE)), " ".join(map(shlex.quote, source_args)))
            script += "chparam {} student_top; hierarchy -check -top student_top; ".format(
                " ".join("-set {} {}".format(key, value) for key, value in overrides.items()))
            script += "proc; opt; select -assert-none t:$dlatch; check -assert"
            record(config, "yosys", ["yosys", "-Q", "-T", "-p", script], out / "yosys.log", 120)
        with ThreadPoolExecutor(max_workers=args.lint_jobs) as executor:
            list(executor.map(lint_config, matrix))

    if args.phase in ("all", "functional"):
        vectors = args.build_root / "vectors"
        for seed in SEEDS:
            if not record(None, "generate-{}".format(seed), [sys.executable,
                          "tools/generate_core_vectors.py", "--out", str(vectors / str(seed)),
                          "--seed", str(seed)], vectors / (str(seed) + ".log"), 30):
                return 1
        for config in representatives:
            out = args.build_root / config_name(config)
            overrides = parameters(config)
            command = ["verilator", "--binary", "--timing", "--trace", "--assert",
                       "--language", "1364-2005", "-Wall", "-Wno-fatal", "-DRV32_TEST_WATCHDOG",
                       "--top-module", "rv32_cpu_core_width_tb", "-Irtl", "--Mdir",
                       str(out / "core-obj"), "-o", "core_tb", "-j", str(args.jobs)]
            command += ["-G{}={}".format(key, value) for key, value in overrides.items()]
            command += [str(path) for path in core_sources] + ["tb/rv32_cpu_core_width_tb.v"]
            if record(config, "core-build", command, out / "core-build.log", 300):
                simulator = (out / "core-obj/core_tb").resolve()
                for seed in SEEDS:
                    root = vectors / str(seed)
                    command = [str(simulator), "+PROGRAM=" + str(root.with_suffix(".words")),
                               "+TRACE=" + str(root.with_suffix(".trace")),
                               "+EXPECTED=" + root.with_suffix(".result").read_text().strip(),
                               "+SEED=" + str(seed)]
                    passed = record(config, "retirement-{}".format(seed), command,
                                    out / ("retirement-{}.log".format(seed)), 30)
                    row = metadata["checks"][-1]
                    row["seed"] = seed
                    if not passed:
                        row["reproduce"] = ["timeout", "30"] + command + [
                            "+WAVE=" + str((out / ("failure-{}.vcd".format(seed))).resolve())]
                    save()
            command = [sys.executable, "tools/build_configured.py", "--framework", str(args.framework),
                       "--filelist", str(args.filelist), "--out", str(out / "official"),
                       "--jobs", str(args.jobs), "--appimage", args.appimage] + configured_options(config)
            if not record(config, "official-build", command, out / "official-build.log", 300):
                continue
            case_report = out / "functional.json"
            case_report.unlink(missing_ok=True)
            command = [sys.executable, "tools/run_width_regression.py", "--framework", str(args.framework),
                       "--testcases", str(args.testcases), "--filelist", str(args.filelist),
                       "--build-root", str(out), "--sim", str(out / "official/sim"),
                       "--report", str(case_report), "--max-cycles", str(args.max_cycles),
                       "--latency", str(args.latency)] + configured_options(config)
            if args.all_performance:
                command.append("--all-performance")
            record(config, "functional", command, out / "functional.log", 43200)
            if case_report.exists():
                metadata["functional"].append(json.loads(case_report.read_text()))
                save()

    metadata["sources_unchanged"] = all(
        hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
    metadata["completed"] = True
    metadata["passed"] = bool(metadata["checks"]) and metadata["sources_unchanged"] and all(
        row["passed"] for row in metadata["checks"])
    metadata["finished_at"] = datetime.now(timezone.utc).isoformat()
    save()
    print("{} parameter matrix; {}".format("PASS" if metadata["passed"] else "FAIL", args.report))
    return int(not metadata["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
