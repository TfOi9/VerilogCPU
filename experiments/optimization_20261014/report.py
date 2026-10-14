#!/usr/bin/env python3
"""Collect completed optimization evidence without promoting incomplete gates."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXP = Path(__file__).resolve().parent
OUT = ROOT / "build/optimization-20261014"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def passed(path):
    record = json.loads(path.read_text())
    if not record.get("passed") or not record.get("completed", True):
        raise ValueError("incomplete or failed gate: " + str(path))
    return record


def main():
    result = {"completed": False, "passed": False, "raw_root": str(OUT)}
    passed(OUT / "final/results.json")
    for path in (OUT / "final/source/rtl").iterdir():
        if path.is_file() and digest(path) != digest(ROOT / "rtl" / path.name):
            raise ValueError("current RTL differs from measured RTL: " + path.name)
    assert digest(OUT / "final/source/verilog/filelist.f") == digest(ROOT / "verilog/filelist.f")
    result["rtl_sha256"] = {p.name: digest(p) for p in sorted((ROOT / "rtl").glob("*")) if p.is_file()}
    suites = {name: passed(OUT / ("suite-" + name) / "results.json") for name in ("baseline", "final")}
    assert all(len(s["results"]) == 2 for s in suites.values())
    result["performance"] = []
    for before, after in zip(suites["baseline"]["results"], suites["final"]["results"]):
        assert before["label"] == after["label"]
        assert len(before["cases"]) == len(after["cases"]) == 25
        assert all(c["passed"] for row in (before, after) for c in row["cases"])
        rows = []
        for a, b in zip(before["cases"], after["cases"]):
            assert a["case"] == b["case"] and a["dynamic_instructions"] == b["dynamic_instructions"]
            if not a["case"].startswith("perf_"):
                continue
            rows.append({"case": a["case"], "before_cycles": a["cycles"], "after_cycles": b["cycles"],
                         "before_ipc": a["ipc"], "after_ipc": b["ipc"],
                         "speedup": a["cycles"]/b["cycles"], "before_profile": a["profile"],
                         "after_profile": b["profile"]})
        result["performance"].append({"cache": before["label"], "cases": rows,
            "before_geomean": before["ipc_geomean"], "after_geomean": after["ipc_geomean"],
            "speedup": after["ipc_geomean"]/before["ipc_geomean"]})
    result["ppa"] = []
    for name in ("ppa-baseline", "ppa-final", "ppa-final-large"):
        path = OUT / name / "results.json"
        record = passed(path)
        archive = OUT / name / "code-archive.json"
        code = json.loads(archive.read_text()) if archive.exists() else None
        for source, sha in record["source_sha256"].items():
            current = Path(source)
            if code and source == code["original_path"]:
                current = Path(code["archive_path"])
            assert digest(current) == sha, str(current)
        report = record["report"]
        margin = passed(Path(record["final_directory"]) / "margin.json")
        assert report["equivalence_passed"] and report["electrical"]["electrical_pass"]
        result["ppa"].append({"label": name, "raw_result": str(path),
            "area_um2": report["area"]["area_um2"], "sram_area_um2": report["area"]["sram_area_um2"],
            "estimated_fmax_mhz": report["timing"]["estimated_fmax_mhz"],
            "setup_slack_at_2ns": report["timing"]["worst_setup_slack_ns"],
            "minimum_hold_slack_ns": margin["worst_slack_ns"],
            "cap_slew_hold_passed": True, "equivalence_passed": True})
    matrix = passed(OUT / "full-matrix.json")
    assert len(matrix["matrix"]) == 81 and len(matrix["functional"]) == 9
    assert matrix["sources_unchanged"] and matrix["all_performance"]
    assert all(f["passed"] and len(f["results"]) == 27 for f in matrix["functional"])
    assert all(digest(Path(path)) == sha for path, sha in matrix["source_sha256"].items())
    units = passed(ROOT / "build/optimization-unit/results.json")
    assert all(digest(Path(path)) == sha for path, sha in units["source_sha256"].items())
    result["validation"] = {"matrix_checks": len(matrix["checks"]), "static_configurations": 81,
        "functional_configurations": 9, "functional_program_runs": 243, "retirement_traces": 27,
        "unit_pass_lines": 0, "optimization_units": len(units["tests"])}
    for name in ("final-unit-v3.log", "final-lint-v3.log"):
        log = OUT / "checks" / name
        lines = log.read_text().splitlines()
        assert not any(line.startswith(("FAIL", "ERROR", "FATAL", "%Error", "make: ***")) for line in lines)
        if name.startswith("final-unit"):
            assert sum(l.startswith("PASS rv32_mdu_reservation_stations tests=") for l in lines) == 3
        else:
            assert sum(l.startswith("PASS core lint FE=") for l in lines) == 9
        result["validation"][name] = {"sha256": digest(log), "pass_lines": sum(l.startswith("PASS") for l in lines)}
    result["validation"]["unit_pass_lines"] = result["validation"]["final-unit-v3.log"]["pass_lines"]
    processes = passed(OUT / "checks/process-results.json")
    assert all(row["observed_exit_code"] == 0 and digest(Path(row["log"])) == row["log_sha256"]
               for row in processes["results"])
    result["validation"]["process_results"] = processes
    result["validation"]["mdu_failure_control"] = passed(OUT / "checks/mdu-negative-control.json")
    result["probes"] = json.loads((OUT / "probes-v2/results.json").read_text())
    result["rejected_store_candidates"] = {name: passed(OUT / name / "results.json")
        for name in ("store-handoff", "store-yield")}
    result.update(completed=True, passed=True)
    (EXP / "results-summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print("PASS final evidence and source audit")


if __name__ == "__main__":
    main()
