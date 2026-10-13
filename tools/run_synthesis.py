#!/usr/bin/env python3
"""Run the official ASAP7 flow for one configuration or nine representatives."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import threading

from run_parameter_matrix import REPRESENTATIVES, config_name, parameters


ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def omit_empty_connections(text):
    """Avoid opt_hier's rejection of legal zero-width empty port connections."""
    port = r"\.[A-Za-z_][A-Za-z_0-9]*\s*\(\s*\)"
    text = re.sub(port + r"\s*,", "", text)
    text = re.sub(r",\s*" + port + r"\s*(?=\))", "", text)
    return re.sub(port + r"\s*(?=\))", "", text)


def configured_sources(sources, config, out):
    """Project public defaults and equivalent omitted connections into build/."""
    tops = [path for path in sources if path.name == "student_top.v"]
    if len(tops) != 1:
        raise ValueError("filelist must contain exactly one student_top.v")
    top = tops[0]
    text = top.read_text()
    for key, value in parameters(config).items():
        pattern = r"(?m)^(\s*parameter\s+(?:integer\s+)?" + key + r"\s*=\s*)\d+(\s*[,\n])"
        text, count = re.subn(pattern, lambda match: match[1] + str(value) + match[2], text)
        if count != 1:
            raise ValueError("expected one literal default for " + key)
    out.mkdir(parents=True, exist_ok=True)
    if len({path.name for path in sources}) != len(sources):
        raise ValueError("source basenames must be unique for synthesis projection")
    projected = []
    for source in sources:
        generated = out / source.name
        generated.write_text(omit_empty_connections(text if source == top else source.read_text()))
        projected.append(generated)
    for source in sources:
        for header in source.parent.glob("*.vh"):
            destination = out / header.name
            if destination.exists() and destination.read_bytes() != header.read_bytes():
                raise ValueError("conflicting header: " + header.name)
            destination.write_bytes(header.read_bytes())
    filelist = out / "filelist.f"
    filelist.write_text("\n".join(str(path.resolve()) for path in projected) + "\n")
    return filelist, projected


def execute(command, log, seconds):
    """Terminate the entire tool tree on timeout, including ABC and OpenSTA."""
    started = time.monotonic()
    status, error = None, None
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as output:
        try:
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                       cwd=ROOT, start_new_session=True)
            try:
                status = process.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                error = "wall timeout after {} seconds".format(seconds)
            if status not in (None, 0):
                error = "process status {}".format(status)
        except OSError as failure:
            error = str(failure)
    if error is None and re.search(r"(?mi)^(?:ERROR|FAIL|%Error|Error(?: \d+)?):?\b",
                                   log.read_text(errors="replace")):
        error = "tool reported an error; see log"
    return {"passed": error is None, "returncode": status, "error": error,
            "log": str(log), "command": command, "timeout_seconds": seconds,
            "elapsed_seconds": round(time.monotonic() - started, 3)}


def validate_report(report, mode, period):
    if report["mode"] != mode:
        raise ValueError("wrong synthesis mode in report")
    area, timing = report["area"], report["timing"]
    keys = ("area_um2", "logic_area_um2", "combinational_area_um2",
            "sequential_area_um2", "sram_area_um2")
    if any(not math.isfinite(area[key]) or area[key] <= 0 for key in keys):
        raise ValueError("missing or invalid logic/SRAM area")
    if not math.isclose(area["area_um2"], area["logic_area_um2"] + area["sram_area_um2"],
                        rel_tol=1e-6):
        raise ValueError("total area does not include SRAM exactly once")
    if not math.isclose(area["logic_area_um2"], area["combinational_area_um2"] +
                        area["sequential_area_um2"], rel_tol=1e-6):
        raise ValueError("inconsistent sequential/combinational area")
    if not area["sram_instances"] or not report["sram_model"]["estimated"]:
        raise ValueError("missing official FakeRAM accounting")
    expected_sram = sum(item["area_um2"] for item in area["sram_instances"])
    if not math.isclose(expected_sram, area["sram_area_um2"], rel_tol=1e-6):
        raise ValueError("SRAM instance area does not match total")
    if not timing["timing_analyzed"] or timing["clock_period_ns"] != period:
        raise ValueError("missing timing analysis or wrong clock period")
    for key in ("minimum_period_ns", "estimated_fmax_mhz", "worst_setup_slack_ns"):
        value = timing[key]
        if value is None or not math.isfinite(value):
            raise ValueError("missing timing result: " + key)
    if timing["minimum_period_ns"] <= 0 or timing["estimated_fmax_mhz"] <= 0:
        raise ValueError("invalid minimum period or frequency")
    if not timing["critical_paths"]:
        raise ValueError("missing critical paths")


def markdown_report(metadata):
    lines = ["# ASAP7 synthesis results", "",
             "Completed: {}. Passed: {}. Sources unchanged: {}.".format(
                 metadata["completed"], metadata["passed"], metadata.get("sources_unchanged", False)),
             "", "Area is in um^2; frequency is in MHz. SRAM uses the official estimated FakeRAM model.",
             "Timing uses an ideal clock and no interconnect parasitics; it is not a post-layout result.",
             "", "| Configuration | Mode | Comb. | Seq. | SRAM | Total | Fmax | Slack (ns) | Status |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    for row in metadata["results"]:
        label = config_name(tuple(row[key] for key in parameters((0, 0, 0, 0))))
        if "report" not in row:
            lines.append("| {} | {} | | | | | | | FAIL |".format(label, row["mode"]))
            continue
        area, timing = row["report"]["area"], row["report"]["timing"]
        lines.append("| {} | {} | {:.3f} | {:.3f} | {:.3f} | {:.3f} | {:.2f} | {:+.4f} | {} |".format(
            label, row["mode"], area["combinational_area_um2"], area["sequential_area_um2"],
            area["sram_area_um2"], area["area_um2"], timing["estimated_fmax_mhz"],
            timing["worst_setup_slack_ns"], "PASS" if row["passed"] else "FAIL"))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", type=Path, default=ROOT.parent / "RISC-V-CPU-2026")
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog/filelist.f")
    parser.add_argument("--out", type=Path, default=ROOT / "build/synth")
    parser.add_argument("--report", type=Path, default=ROOT / "reports/synthesis.json")
    parser.add_argument("--mode", choices=("opt", "diagnose", "both"), default="opt")
    parser.add_argument("--matrix", action="store_true")
    parser.add_argument("--fe-width", type=int, default=1)
    parser.add_argument("--be-width", type=int, default=1)
    parser.add_argument("--phys-regs", type=int, default=64)
    parser.add_argument("--rob-entries", type=int, default=32)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--clock-period", type=float, default=2.0)
    parser.add_argument("--yosys", default=str(ROOT / ".deps/yosys/bin/yosys"))
    parser.add_argument("--abc", default=str(ROOT / ".deps/yosys/bin/yosys-abc"))
    parser.add_argument("--sta", default=str(ROOT / ".deps/opensta/bin/sta"))
    parser.add_argument("--asap7-lib", type=Path, default=ROOT / ".deps/asap7/lib")
    parser.add_argument("--appimage", default="")
    args = parser.parse_args()
    config = (args.fe_width, args.be_width, args.phys_regs, args.rob_entries)
    if config[0] not in (1, 2, 4) or config[1] not in (1, 2, 4) or config[2] < 33:
        parser.error("widths must be 1, 2, or 4 and PHYS_REGS must be at least 33")
    if config[3] < max(2, config[1]) or config[3] & (config[3] - 1):
        parser.error("ROB_ENTRIES must be a power of two at least max(2, BE_WIDTH)")
    if args.jobs < 1 or args.timeout < 1 or not math.isfinite(args.clock_period) or args.clock_period <= 0:
        parser.error("jobs, timeout and clock period must be positive and finite")
    framework = args.framework.resolve()
    sys.path.insert(0, str(framework / "scripts"))
    from build import read_sources
    from fakeram import RAM_SOURCE
    sources = read_sources(args.filelist)
    dependencies = set(sources + [RAM_SOURCE, args.filelist.resolve(), Path(__file__),
                                 ROOT / "tools/run_parameter_matrix.py"])
    dependencies.update(header for source in sources for header in source.parent.glob("*.vh"))
    dependencies.update((framework / "scripts").glob("*.py"))
    dependencies.add(framework / "scripts/timing.tcl")
    dependencies.add(framework / "Makefile")
    dependencies.add(ROOT / "Makefile")
    dependencies.update(args.asap7_lib.resolve().glob("*.lib"))
    lock = ROOT / "third_party/synthesis-lock.json"
    if lock.exists():
        dependencies.add(lock)
    native_tools = {}
    if not args.appimage:
        for name, command in (("yosys", args.yosys), ("abc", args.abc), ("opensta", args.sta)):
            executable = shutil.which(command)
            if executable:
                path = Path(executable).resolve()
                dependencies.add(path)
                native_tools[name] = {"path": str(path), "sha256": digest(path)}
    hashes = {str(path): digest(path) for path in sorted(dependencies)}
    configs = list(REPRESENTATIVES) if args.matrix else [config]
    modes = ["diagnose", "opt"] if args.mode == "both" else [args.mode]
    metadata = {"schema_version": 1, "started_at": datetime.now(timezone.utc).isoformat(),
                "matrix": args.matrix, "configurations": [parameters(c) for c in configs],
                "modes": modes, "clock_period_ns": args.clock_period,
                "source_sha256": hashes, "native_tools": native_tools,
                "completed": False, "passed": False, "results": []}
    args.report = args.report.resolve()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    guard = threading.Lock()

    def save():
        temporary = args.report.with_suffix(".tmp")
        temporary.write_text(json.dumps(metadata, indent=2, allow_nan=False) + "\n")
        temporary.replace(args.report)
        args.report.with_suffix(".md").write_text(markdown_report(metadata))

    save()

    def run_config(current):
        out = args.out.resolve() / config_name(current)
        filelist, projected = configured_sources(sources, current, out / "input")
        command = ["iverilog", "-g2005", "-D", "SYNTHESIS", "-I", str(ROOT / "rtl"),
                   "-s", "student_top", "-o", str(out / "input/top.vvp"), str(RAM_SOURCE)]
        command += [str(path) for path in projected]
        frontend = execute(command, out / "verilog-2005.log", 60)
        if frontend["passed"]:
            frontend["startup"] = execute(["vvp", "-N", str(out / "input/top.vvp")],
                                          out / "parameters.log", 30)
            frontend["passed"] = frontend["startup"]["passed"]
        for mode in modes:
            report_path = out / mode / "report.json"
            report_path.unlink(missing_ok=True)
            command = ["make", "--no-print-directory", "-f", str(framework / "Makefile"),
                       "synth", "PYTHON=" + sys.executable, "FILELIST=" + str(filelist),
                       "SYNTH_OUT=" + str(out), "MODE=" + mode,
                       "CLOCK_PERIOD_NS=" + str(args.clock_period), "APPIMAGE=" + args.appimage]
            if not args.appimage:
                command += ["YOSYS=" + args.yosys, "ABC=" + args.abc, "STA=" + args.sta,
                            "ASAP7_LIB=" + str(args.asap7_lib.resolve())]
            if frontend["passed"]:
                row = execute(command, out / (mode + ".log"), args.timeout)
            else:
                row = {"passed": False, "error": "Verilog 2005 or parameter check failed"}
            row.update(parameters(current))
            row.update(mode=mode, frontend=frontend, report_path=str(report_path),
                       generated_source_sha256={str(path): digest(path) for path in projected})
            if row["passed"]:
                try:
                    report = json.loads(report_path.read_text())
                    validate_report(report, mode, args.clock_period)
                    row["report"] = report
                except (ValueError, KeyError, OSError, TypeError) as error:
                    row.update(passed=False, error="report validation: " + str(error))
            with guard:
                metadata["results"].append(row)
                save()
                print("{} {} {}{}".format("PASS" if row["passed"] else "FAIL",
                      config_name(current), mode, " " + row["error"] if row.get("error") else ""), flush=True)

    with ThreadPoolExecutor(max_workers=min(args.jobs, len(configs))) as pool:
        list(pool.map(run_config, configs))
    metadata["sources_unchanged"] = all(Path(path).is_file() and digest(Path(path)) == value
                                        for path, value in hashes.items())
    metadata["completed"] = len(metadata["results"]) == len(configs) * len(modes)
    metadata["passed"] = metadata["completed"] and metadata["sources_unchanged"] and all(
        row["passed"] for row in metadata["results"])
    metadata["finished_at"] = datetime.now(timezone.utc).isoformat()
    save()
    print("Synthesis report: " + str(args.report))
    return 0 if metadata["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as failure:
        print("error: " + str(failure), file=sys.stderr)
        sys.exit(2)
