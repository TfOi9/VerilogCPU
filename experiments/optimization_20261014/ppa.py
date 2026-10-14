#!/usr/bin/env python3
"""Map a frozen 2x2 snapshot with the existing fast flow and 20 ps hold goal."""
import argparse
import json
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "experiments/round4_tree"))
from common_synth import FAST_SYNTH
import repair
from margin import close
sys.path.insert(0, str(ROOT / "tools"))
from run_synthesis import configured_sources, validate_report
from build_configured import cache_geometry
sys.path.insert(0, str(ROOT.parent / "RISC-V-CPU-2026/scripts"))
from build import read_sources
import synth as official


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--icache", type=cache_geometry, default=(1024, 64, 1))
    parser.add_argument("--dcache", type=cache_geometry, default=(4096, 256, 1))
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    originals = read_sources(args.source.resolve() / "verilog/filelist.f")
    configured, projected = configured_sources(originals, (2, 2, 64, 32), out / "input")
    top = out / "input/student_top.v"
    text = top.read_text()
    for prefix, values in (("I", args.icache), ("D", args.dcache)):
        for field, value in zip(("SIZE_BYTES", "NUM_SETS", "NUM_WAYS"), values):
            pattern = r"(parameter integer " + prefix + "CACHE_" + field + r" = )\d+"
            text, count = re.subn(pattern, lambda match: match[1] + str(value), text)
            if count != 1:
                raise ValueError("cache parameter projection failed")
    top.write_text(text)
    shutil.copyfile(Path(__file__), out / "ppa.py")
    dependencies = originals + projected + list((out / "input").glob("*.vh"))
    dependencies += [out / "ppa.py", ROOT / "experiments/round4_tree/common_synth.py",
                     ROOT / "experiments/round4_tree/margin.py",
                     ROOT / "experiments/round3_electrical/repair.py"]
    hashes = {str(p): repair.digest(p) for p in dependencies}
    record = {"completed": False, "passed": False, "source_sha256": hashes,
              "configuration": {"FE_WIDTH": 2, "BE_WIDTH": 2, "PHYS_REGS": 64,
                                "ROB_ENTRIES": 32, "icache": args.icache, "dcache": args.dcache}}
    def verify_snapshot():
        if any(not Path(p).is_file() or repair.digest(Path(p)) != sha for p, sha in hashes.items()):
            raise ValueError("frozen PPA inputs changed")
    # The old experiment's checkout guard is replaced by this snapshot guard.
    # CEC, fixed-state checks and electrical/hold checks remain unchanged.
    repair.verify = verify_snapshot
    def run_yosys(yosys, dest, label, commands):
        rewritten = []
        for command in commands:
            rewritten.extend(FAST_SYNTH if command.startswith("synth -top student_top ") else [command])
        script = dest / (label + ".ys")
        script.write_text("\n".join(rewritten) + "\n")
        repair.execute([yosys, "-Q", "-T", "-s", script], dest / (label + ".log"),
                       2400 if label == "synth" else 240)
    official.run_yosys = run_yosys
    try:
        sys.argv = ["synth.py", "--filelist", str(configured), "--out", str(out / "mapping"),
            "--mode", "opt", "--clock-period", "2.0", "--yosys", str(ROOT / ".deps/yosys/bin/yosys"),
            "--abc", str(ROOT / ".deps/yosys/bin/yosys-abc"),
            "--sta", str(ROOT / ".deps/opensta/bin/sta"), "--asap7-lib", str(ROOT / ".deps/asap7/lib")]
        official.main()
        original = out / "mapping/opt"
        validate_report(json.loads((original / "report.json").read_text()), "opt", 2.0)
        repair.repair(original, out / "electrical")
        repair.merge_and_analyze(original, out / "electrical")
        electrical = repair.refine_electrical(original, out / "electrical")
        if not electrical["electrical_pass"]:
            raise ValueError("electrical constraints did not converge")
        result = close(original, Path(electrical["final_directory"]), out / "hold")
        verify_snapshot()
        record.update(result)
        report = json.loads((Path(result["final_directory"]) / "report.json").read_text())
        record["report"] = report
        print("PASS PPA", report["timing"]["estimated_fmax_mhz"], flush=True)
    except Exception as error:
        record["error"] = str(error)
        raise
    finally:
        (out / "results.json").write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
