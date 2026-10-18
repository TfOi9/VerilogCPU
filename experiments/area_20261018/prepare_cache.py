#!/usr/bin/env python3
"""Prepare a smaller D-cache candidate and audit its explicit projection."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from measure import ROOT, save, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--bytes', type=int, default=8192)
    parser.add_argument('--ways', type=int, choices=(1, 2, 4), default=2)
    parser.add_argument('--fe', type=int, default=4)
    args = parser.parse_args()
    assert args.bytes % (16 * args.ways) == 0
    sets = args.bytes // (16 * args.ways)
    assert sets >= 2 and sets & (sets - 1) == 0
    command = [sys.executable, '-B', str(Path(__file__).with_name('measure.py')),
               '--phase', 'prepare', '--fe', str(args.fe), '--directory', '0', '--phys', '56',
               '--hints', '16', '--out', str(args.out)]
    subprocess.run(command, cwd=ROOT, check=True)
    out = args.out.resolve()
    top = out / 'input/student_top.v'
    text = top.read_text()
    values = {'DCACHE_SIZE_BYTES': args.bytes, 'DCACHE_NUM_SETS': sets, 'DCACHE_NUM_WAYS': args.ways}
    for key, value in values.items():
        text, count = re.subn(r'(parameter integer ' + key + r' = )\d+',
                             lambda m: m[1] + str(value), text)
        assert count == 1
    top.write_text(text)
    snapshot = json.loads((out / 'snapshot.json').read_text())
    snapshot['configuration'].update(values)
    snapshot['sha256'][str(top)] = digest(top)
    snapshot['sha256'][str(Path(__file__).resolve())] = digest(Path(__file__))
    save(out / 'snapshot.json', snapshot)


if __name__ == '__main__':
    main()
