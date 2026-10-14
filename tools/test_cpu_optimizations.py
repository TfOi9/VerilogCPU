#!/usr/bin/env python3
"""Check selector ordering and recovery widths independently of issue width."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/optimization-unit"


def run(command, name, seconds=60):
    command = ["timeout", "-k", "5", str(seconds), *map(str, command)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    log = result.stdout + result.stderr
    (OUT / (name + ".log")).write_text(log)
    assert result.returncode == 0 and not re.search(r"(?m)^(FAIL|ERROR|%Error)\b", log), name
    return log


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sources = [*sorted((ROOT / "rtl").glob("*.v")), *sorted((ROOT / "tb").glob("*.v"))]
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    results = []
    for entries in (1, 3, 4, 6, 7, 8, 16):
        for ports in (1, 2, 4):
            top = "rv32_ranked_select_tb"
            name = f"selector-{entries}-{ports}"
            run(["iverilog", "-g2005", "-s", top,
                 "-P", f"{top}.ENTRIES={entries}", "-P", f"{top}.PORTS={ports}",
                 "-P", f"{top}.SLOT_WIDTH={max(1, (entries-1).bit_length())}",
                 "-o", OUT / name, ROOT / "rtl/rv32_ranked_select.v",
                 ROOT / "tb" / (top + ".v")], name + "-build")
            assert "PASS ranked_select" in run(["vvp", "-N", OUT / name], name)
            results.append(name)
    for be in (1, 2, 4):
        vectors = OUT / f"rob-vectors-{be}.txt"
        run([sys.executable, ROOT / "tools/generate_rob_vectors.py", vectors,
             "--entries", "32", "--width", be], f"rob-vectors-{be}")
        for recovery in (1, 2, 4, 8):
            for module in ("rv32_reorder_buffer", "rv32_rename_unit"):
                top = module + "_tb"
                name = f"{module}-{be}-recovery{recovery}"
                run(["iverilog", "-g2005", "-I", "rtl", "-s", top,
                     "-P", f"{top}.BE_WIDTH={be}",
                     "-P", f"{top}.RECOVERY_WIDTH={recovery}",
                     "-o", OUT / name, ROOT / "rtl" / (module + ".v"),
                     ROOT / "tb" / (top + ".v")], name + "-build")
                extra = ["+VECTOR_FILE=" + str(vectors)] if module == "rv32_reorder_buffer" else []
                assert "PASS" in run(["vvp", "-N", OUT / name, *extra], name)
                results.append(name)
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == sha for p, sha in hashes.items())
    (OUT / "results.json").write_text(json.dumps({"passed": True, "tests": results,
        "source_sha256": hashes}, indent=2) + "\n")
    print(f"PASS optimization units: {len(results)} configurations, 21000 selector trials")


if __name__ == "__main__":
    main()
