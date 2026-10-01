#!/usr/bin/env python3
"""Check that a test build fails when instruction responses stop forever."""

import argparse
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", type=Path)
    args = parser.parse_args()
    root = Path("build/core-vectors/0x2401")
    command = [str(args.simulator.resolve()), "+PROGRAM=" + str(root.with_suffix(".words")),
               "+TRACE=" + str(root.with_suffix(".trace")),
               "+EXPECTED=" + root.with_suffix(".result").read_text().strip(), "+SEED=0"]
    process = subprocess.run(command, capture_output=True, text=True, timeout=30)
    output = process.stdout + process.stderr
    Path("build/step24-watchdog.log").write_text(output, encoding="utf-8")
    if process.returncode == 0 or "ERROR rv32_cpu_core no retirement for 100000 cycles" not in output:
        raise SystemExit("FAIL no-retirement watchdog\n" + output)
    print("PASS no-retirement watchdog stopped a stalled fetch")


if __name__ == "__main__":
    main()
