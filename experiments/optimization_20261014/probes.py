#!/usr/bin/env python3
"""Run independent hot-store and alternating-branch probes on frozen builds."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from generate_core_vectors import branch, execute, immediate, store


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--builds", nargs="+", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    results = []
    for kind in ("hot-store", "alternating-branch"):
        words = [0x000100b7, immediate(2, 0, 100), immediate(3, 0, 85 if kind == "hot-store" else 0), store(3, 1, 0)]
        loop = len(words)*4
        if kind == "hot-store":
            words.extend(store(3, 1, 0) for _ in range(32))
        else:
            words += [immediate(3, 3, 1, 4), branch(3, 0, 68, 1)]
            words.extend(immediate(10, 10, 1) for _ in range(16))
        words += [immediate(2, 2, -1)]
        words += [branch(2, 0, loop-len(words)*4, 1)]
        if kind == "hot-store":
            words += [immediate(10, 1, 0, 2, 0x03)]
        words += [0x80000fb7, store(10, 31, 0)]
        reference, expected = execute(words)
        image = args.out / (kind + ".data")
        image.write_text("@00000000\n" + "\n".join(" ".join(f"{b:02x}"
            for b in word.to_bytes(4, "little")) for word in words) + "\n")
        for build in args.builds:
            sim = (build / "baseline/sim").resolve()
            command = ["timeout", "-k", "5", "30", str(sim), str(image.resolve()),
                       str(expected), "100000", "10"]
            result = subprocess.run(command, capture_output=True, text=True)
            name = build.name + "-" + kind
            (args.out / (name + ".log")).write_text(result.stdout + result.stderr)
            match = re.fullmatch(r"PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*", result.stdout)
            assert result.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, name
            results.append({"build": str(build), "probe": kind, "cycles": int(match[1]),
                "instructions": len(reference), "expected": expected, "command": command,
                "sim_sha256": hashlib.sha256(sim.read_bytes()).hexdigest(),
                "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest()})
            print(name, match[1], flush=True)
    (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
