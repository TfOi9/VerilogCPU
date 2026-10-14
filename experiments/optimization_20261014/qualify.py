#!/usr/bin/env python3
"""Run all official cases on an existing frozen, profiled simulator."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pilot", HERE.parent / "cache_20261014/run.py")
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


def run_case(sim, case, out):
    expected = int((case / "expected.txt").read_text())
    instructions = json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
    command = ["timeout", "-k", "5", "120", str(sim), str(case / "program.data"),
               str(expected), "30000000", "10"]
    result = subprocess.run(command, text=True, capture_output=True)
    log = out / (case.name + ".log")
    log.write_text(result.stdout + result.stderr)
    pilot.save(out / (case.name + ".command.json"), command)
    match = re.fullmatch(r"PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*", result.stdout)
    assert result.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, case.name
    profiles = re.findall(r"^PROFILE (.*)$", result.stderr, re.MULTILINE)
    assert len(profiles) == 1
    profile = json.loads(profiles[0])
    counts = profile["counts"]
    cycles = int(match[1])
    assert sum(v for k, v in counts.items() if k.startswith("partition_")) == counts["cycles"] == cycles
    assert counts["retired"] == instructions - 1
    assert sum(int(k)*v for k, v in profile["recovery_lengths"].items()) == counts.get("partition_recovery", 0)
    assert sum(int(k)*v for k, v in profile["rollback_depths"].items()) == counts.get("rollback_entries", 0)
    return {"case": case.name, "passed": True, "cycles": cycles, "ipc": instructions/cycles,
            "dynamic_instructions": instructions, "profile": profile, "log_sha256": pilot.digest(log)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    result_path = out / "results.json"
    source_record = json.loads((build / "results.json").read_text())
    assert source_record["completed"] and source_record["passed"]
    for path, sha in source_record["source_sha256"].items():
        assert pilot.digest(Path(path)) == sha, path
    cases = sorted(pilot.CASES.glob("correctness_*")) + sorted(pilot.CASES.glob("perf_*"))
    report = {"completed": False, "passed": False, "results": []}
    try:
        for config in source_record["results"]:
            sim = build / config["label"] / "sim"
            assert pilot.digest(sim) == config["sim_sha256"]
            row = {"label": config["label"], "sim_sha256": config["sim_sha256"], "cases": []}
            report["results"].append(row)
            logs = out / config["label"]
            logs.mkdir()
            for case in cases:
                row["cases"].append(run_case(sim, case, logs))
                print("PASS", config["label"], case.name, flush=True)
            performance = [c for c in row["cases"] if c["case"].startswith("perf_")]
            assert len(performance) == 6
            row["ipc_geomean"] = math.exp(sum(math.log(c["ipc"]) for c in performance)/6)
        report.update(completed=True, passed=True)
    finally:
        result_path.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
