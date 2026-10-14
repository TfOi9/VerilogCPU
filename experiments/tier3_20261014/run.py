#!/usr/bin/env python3
"""Investigate the current tier-three gap on immutable simulation snapshots."""
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('deep', ROOT/'experiments/deep_20261014/run.py')
deep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deep)
deep.HERE = HERE
geometry = (1024, 1, 16384, 2)
deep.VARIANTS = {
    'baseline': (geometry, {}, {}),
    'hints64': (geometry, {'STORE_HINTS': 64}, {}),
    'be4': (geometry, {'BE_WIDTH': 4}, {}),
    'wide4': (geometry, {'FE_WIDTH': 4, 'BE_WIDTH': 4}, {}),
    'window': (geometry, {'PHYS_REGS': 96, 'ROB_ENTRIES': 64}, {}),
    'lsq16': (geometry, {}, {'LSQ_ENTRIES': 16, 'LSQ_INDEX_WIDTH': 4, 'LSQ_TAG_WIDTH': 6}),
    'recovery8': (geometry, {'RECOVERY_WIDTH': 8}, {}),
    'predictor': (geometry, {}, {'predictor': True}),
    'd8': ((1024, 1, 8192, 2), {}, {}),
    'd32': ((1024, 1, 32768, 2), {}, {}),
}
original_harness = deep.pilot.make_harness
original_case = deep.pilot.run_case


def make_harness(out):
    base = ROOT/'experiments/deep_20261014/profile.h'
    (out/'base_profile.h').write_bytes(base.read_bytes())
    return original_harness(out)


def run_case(sim, case):
    result = original_case(sim, case)
    matches = re.findall(r'^DETAIL (.*)$', (sim.parent/(case+'.stderr')).read_text(), re.M)
    assert len(matches) == 1
    result['detail'] = json.loads(matches[0])
    detail = result['detail']
    counts = result['profile']['counts']
    assert sum(detail['retired_branch_count'].values()) == counts['retired_control']
    assert sum(detail['refill_lines'].values()) == counts.get('dcache_refills', 0)
    assert sum(detail['load_latencies'].values()) == counts.get('detail_load_responses', 0)
    return result


deep.pilot.make_harness = make_harness
deep.pilot.run_case = run_case


if __name__ == '__main__':
    paths = list((ROOT/'rtl').glob('*')) + [ROOT/'verilog/filelist.f', Path(__file__), HERE/'profile.h',
        ROOT/'experiments/deep_20261014/profile.h', ROOT/'experiments/deep_20261014/run.py',
        ROOT/'experiments/cache_20261014/run.py', deep.pilot.FRAMEWORK/'scripts/sim.cpp',
        deep.pilot.FRAMEWORK/'scripts/fakeram.v']
    for case in deep.CASES:
        paths += [deep.pilot.CASES/case/name for name in ('program.data', 'expected.txt', 'metrics.json')]
    hashes = {str(p): deep.pilot.digest(p) for p in paths if p.is_file()}
    out = Path(sys.argv[sys.argv.index('--out')+1]).resolve()
    try:
        deep.main()
    finally:
        if out.exists():
            audit = {'input_sha256': hashes,
                     'unchanged': all(deep.pilot.digest(Path(p)) == h for p, h in hashes.items())}
            (out/'input-audit.json').write_text(json.dumps(audit, indent=2)+'\n')
            assert audit['unchanged']
