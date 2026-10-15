#!/usr/bin/env python3
"""Screen directory sizes at fixed cache geometry on immutable snapshots."""
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('tier', ROOT/'experiments/tier3_20261014/run.py')
tier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tier)
deep = tier.deep
deep.HERE = HERE
deep.VARIANTS = {
    f'be{be}-dir{directory}': ((1024, 1, 16384, 2),
                             {'BE_WIDTH': be, 'STORE_DIRECTORY_ENTRIES': directory}, {})
    for be in (2, 4) for directory in (0, 32, 64, 128, 256)
}


if __name__ == '__main__':
    inputs = [Path(__file__), HERE/'profile.h', ROOT/'experiments/tier3_20261014/run.py',
              ROOT/'experiments/deep_20261014/run.py', ROOT/'experiments/deep_20261014/profile.h',
              ROOT/'experiments/cache_20261014/run.py', deep.pilot.FRAMEWORK/'scripts/sim.cpp',
              deep.pilot.FRAMEWORK/'scripts/fakeram.v']
    for case in deep.CASES:
        inputs += [deep.pilot.CASES/case/name for name in ('program.data', 'expected.txt', 'metrics.json')]
    hashes = {str(p): deep.pilot.digest(p) for p in inputs if p.is_file()}
    out = Path(sys.argv[sys.argv.index('--out')+1]).resolve()
    try:
        deep.main()
    finally:
        if out.exists():
            unchanged = all(deep.pilot.digest(Path(p)) == h for p, h in hashes.items())
            (out/'input-audit.json').write_text(json.dumps({'input_sha256': hashes,
                                                         'unchanged': unchanged}, indent=2)+'\n')
            assert unchanged
