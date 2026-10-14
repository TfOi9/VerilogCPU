#!/usr/bin/env python3
"""Run a serial, bounded cache pilot; never infer full-suite qualification."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
EXP = Path(__file__).resolve().parent
FRAMEWORK = ROOT.parent / "RISC-V-CPU-2026"
CASES = ROOT.parent / "RISC-V-CPU-2026-Testcases"
VARIANTS = {
    "baseline": (1024, 1, 4096, 1),
    "d4k-2way": (1024, 1, 4096, 2),
    "i2k-d16k-2way": (2048, 1, 16384, 2),
}
PILOT_CASES = ("perf_multiply", "perf_qsort", "perf_rsort")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def execute(command, log, seconds):
    # GNU timeout terminates the whole foreground process group, including builds.
    command = [shutil.which("timeout") or "timeout", "-k", "5", str(seconds),
               *map(str, command)]
    save(log.with_suffix(".command.json"), command)
    with log.open("w") as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)


def cache_parameters(config):
    result = {}
    for prefix, size, ways in (("I", config[0], config[1]),
                               ("D", config[2], config[3])):
        sets = size // (16 * ways)
        if size != sets * ways * 16 or sets < 2 or sets & (sets - 1):
            raise ValueError("invalid cache geometry")
        result.update({prefix + "CACHE_SIZE_BYTES": size,
                       prefix + "CACHE_NUM_SETS": sets,
                       prefix + "CACHE_NUM_WAYS": ways})
    return result


def sram_estimate(parameters, ram_shape):
    arrays = []
    for prefix in ("I", "D"):
        sets = parameters[prefix + "CACHE_NUM_SETS"]
        ways = parameters[prefix + "CACHE_NUM_WAYS"]
        tag_bits = 28 - (sets.bit_length() - 1)
        for name, width, granularity in (("data", 128, 8),
                                         ("tag", tag_bits, tag_bits)):
            shape = ram_shape(sets, width, granularity)
            arrays.append({"cache": prefix, "array": name, "ways": ways,
                           "depth": sets, "width": width,
                           "area_um2": ways * shape.lanes * shape.lane_area})
    return {"arrays": arrays, "area_um2": sum(a["area_um2"] for a in arrays),
            "includes_logic_valid_dirty_replacement": False}


def make_harness(out):
    source = (FRAMEWORK / "scripts/sim.cpp").read_text()
    replacements = (
        ('#include "Vstudent_top.h"', '#include "Vstudent_top.h"\n#include "profile.h"'),
        ("Vstudent_top top{&context};", "Vstudent_top top{&context};\n        Profile profile;"),
        ("memory.step(top, latency);", "profile.sample(top);\n            memory.step(top, latency);"),
        ("top.final();", "profile.report();\n        top.final();"),
    )
    for old, new in replacements:
        if source.count(old) != 1:
            raise ValueError("official harness marker changed: " + old)
        source = source.replace(old, new)
    path = out / "profile_sim.cpp"
    path.write_text(source)
    return path


def run_case(sim, name):
    case = CASES / name
    instructions = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
    expected = int((case / "expected.txt").read_text())
    command = [str(sim), str(case / "program.data"), str(expected), "3000000", "10"]
    process = subprocess.run(command, text=True, capture_output=True, timeout=30)
    log = sim.parent / name
    log.with_suffix(".stdout").write_text(process.stdout)
    log.with_suffix(".stderr").write_text(process.stderr)
    save(log.with_suffix(".command.json"), command)
    match = re.fullmatch(r"PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*", process.stdout)
    if process.returncode or not match or int(match[2]) != expected or int(match[3]) != expected:
        raise ValueError("official case failed: " + str(log))
    profiles = re.findall(r"^PROFILE (.*)$", process.stderr, re.MULTILINE)
    if len(profiles) != 1 or re.search(r"(?mi)^(?:ERROR|FAIL|%Error)\b", process.stderr):
        raise ValueError("invalid profile: " + str(log))
    profile = json.loads(profiles[0])
    cycles = int(match[1])
    counts = profile["counts"]
    partition = sum(v for k, v in counts.items() if k.startswith("partition_"))
    gaps = sum(profile["request_gaps"].values())
    if not (0 < cycles <= 3000000 and counts["cycles"] == partition == cycles and
            counts["retired"] == instructions - 1 and
            gaps == counts.get("store_requests", 0) + counts.get("load_requests", 0) - 1):
        raise ValueError("profile accounting mismatch: " + str(log))
    return {"case": name, "passed": True, "cycles": cycles,
            "dynamic_instructions": instructions, "ipc": instructions / cycles,
            "profile": profile,
            "stdout_sha256": digest(log.with_suffix(".stdout")),
            "stderr_sha256": digest(log.with_suffix(".stderr"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/cache-20261014")
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=list(VARIANTS))
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "results.json").exists():
        raise ValueError("choose a fresh output directory to preserve prior evidence")
    sys.path.insert(0, str(FRAMEWORK / "scripts"))
    from build import read_sources
    from fakeram import Shape, with_ram_source

    sources = with_ram_source(read_sources(ROOT / "verilog/filelist.f"))
    dependencies = set(sources) | set((ROOT / "rtl").glob("*.vh"))
    dependencies.update((EXP / "profile.h", Path(__file__).resolve(),
                         ROOT / "verilog/filelist.f", FRAMEWORK / "scripts/sim.cpp",
                         FRAMEWORK / "scripts/fakeram.py", FRAMEWORK / "scripts/build.py"))
    for name in PILOT_CASES:
        dependencies.update(CASES / name / f for f in ("program.data", "metrics.json", "expected.txt"))
    hashes = {str(p): digest(p) for p in sorted(dependencies)}
    report = {"started_at": datetime.now(timezone.utc).isoformat(),
              "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "source_sha256": hashes, "cpu": {"FE_WIDTH": 2, "BE_WIDTH": 2,
                                                "PHYS_REGS": 64, "ROB_ENTRIES": 32},
              "latency": 10, "build_jobs": 1, "case_jobs": 1,
              "build_timeout_seconds": 240, "case_timeout_seconds": 30,
              "case_scope": list(PILOT_CASES), "full_suite": False,
              "synthesis_run": False, "completed": False, "passed": False, "results": []}
    save(out / "results.json", report)
    harness = make_harness(out)
    try:
        for label in args.variants:
            dest = out / label
            dest.mkdir()
            parameters = cache_parameters(VARIANTS[label])
            command = ["verilator", "--cc", "--exe", "--build", "--trace", "--assert",
                       "-DRV32_TEST_WATCHDOG", "-Wall", "-Wno-fatal", "--top-module", "student_top",
                       "--Mdir", str(dest / "obj"), "-o", str(dest / "sim"), "-j", "1",
                       "-I" + str(ROOT / "rtl"), "-CFLAGS", "-std=c++17 -I" + str(EXP)]
            command += ["-G{}={}".format(k, v) for k, v in (report["cpu"] | parameters).items()]
            command += list(map(str, sources)) + [str(harness)]
            print("BUILD", label, "jobs=1 timeout=240s", flush=True)
            execute(command, dest / "build.log", 240)
            row = {"label": label, "parameters": parameters,
                   "sram_only_estimate": sram_estimate(parameters, Shape),
                   "sim_sha256": digest(dest / "sim"), "cases": []}
            report["results"].append(row)
            for name in PILOT_CASES:
                case = run_case(dest / "sim", name)
                row["cases"].append(case)
                save(out / "results.json", report)
                print(label, name, "PASS cycles=" + str(case["cycles"]),
                      "IPC={:.6f}".format(case["ipc"]), flush=True)
            row["subset_ipc_geomean"] = math.exp(sum(math.log(c["ipc"]) for c in row["cases"]) / len(PILOT_CASES))
        report["sources_unchanged"] = all(Path(p).is_file() and digest(Path(p)) == sha for p, sha in hashes.items())
        report["completed"] = True
        report["passed"] = report["sources_unchanged"]
        if not report["passed"]:
            raise ValueError("source changed during pilot")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        save(out / "results.json", report)


if __name__ == "__main__":
    main()
