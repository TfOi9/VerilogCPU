#!/usr/bin/env python3
"""Freeze RTL and measure recovery and store handoff with bounded simulations."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location("pilot", HERE.parent / "cache_20261014/run.py")
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--recovery-width", type=int)
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--store-mode", choices=("none", "handoff", "yield"), default="none")
    parser.add_argument("--variants", nargs="+", default=["baseline", "i2k-d16k-2way"])
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    snapshot = out / "source"
    shutil.copytree(args.source / "rtl", snapshot / "rtl")
    shutil.copytree(args.source / "verilog", snapshot / "verilog")
    shutil.copyfile(HERE / "profile.h", out / "profile.h")
    shutil.copyfile(Path(__file__), out / "run.py")
    if args.store_mode != "none":
        patch = HERE / ("store-" + args.store_mode + ".patch")
        shutil.copyfile(patch, out / patch.name)
        subprocess.run(["patch", "--batch", "-p1", "-i", str(patch)], cwd=snapshot,
                       check=True, timeout=10)
    pilot.ROOT = snapshot
    pilot.EXP = out
    pilot.VARIANTS.update({"d8k-2way": (1024, 1, 8192, 2),
                           "d16k-2way": (1024, 1, 16384, 2)})
    if args.recovery_width is not None:
        original = pilot.cache_parameters
        def parameters(config):
            return original(config) | {"RECOVERY_WIDTH": args.recovery_width}
        pilot.cache_parameters = parameters
    sys.argv = [sys.argv[0], "--out", str(out), "--variants", *args.variants]
    pilot.main()
    report = json.loads((out / "results.json").read_text())
    try:
        for row in report["results"]:
            for case in row["cases"]:
                p = case["profile"]
                c = p["counts"]
                assert sum(int(k)*v for k, v in p["recovery_lengths"].items()) == c.get("partition_recovery", 0)
                assert sum(p["recovery_lengths"].values()) == c.get("recovery_events", 0)
                assert sum(int(k)*v for k, v in p["rollback_depths"].items()) == c.get("rollback_entries", 0)
        report["accounting_passed"] = True
    except Exception:
        report.update(passed=False, accounting_passed=False)
        raise
    finally:
        report["runner_sha256"] = pilot.digest(out / "run.py")
        pilot.save(out / "results.json", report)
    print("PASS recovery accounting", flush=True)


if __name__ == "__main__":
    main()
