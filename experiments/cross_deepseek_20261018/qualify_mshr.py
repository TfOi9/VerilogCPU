#!/usr/bin/env python3
"""Check the selected directory together with tagged dual-MSHR behavior."""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/area_20261018'))
from measure import FRAMEWORK, digest, run, save


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    directory = json.loads((candidate / 'snapshot.json').read_text())['configuration']['STORE_DIRECTORY_ENTRIES']
    out = candidate / 'mshr'
    out.mkdir(parents=True, exist_ok=False)
    ram = FRAMEWORK / 'scripts/ram/sram_fakeram.sv'
    cache = candidate / 'input/rv32_l1_data_cache.v'
    tb = ROOT / 'tb/rv32_cache_mshr_tb.v'
    files = [ram, cache, tb, Path(__file__)]
    result = {'completed': False, 'passed': False, 'directory': directory,
              'sha256': {str(p): digest(p) for p in files}, 'tests': []}
    try:
        for latency, seed in ((1, 1), (7, 7), (31, 42)):
            name = str(latency) + '-' + str(seed)
            exe = out / name
            parameters = {'WAYS': 2, 'DIRECTORY': directory, 'LATE_CONFIRM': 1,
                          'AUX': 1, 'LATENCY': latency, 'SEED': seed}
            options = [v for k, n in parameters.items() for v in ('-P', 'rv32_cache_mshr_tb.' + k + '=' + str(n))]
            run(['iverilog', '-g2012', '-s', 'rv32_cache_mshr_tb', *options,
                 '-o', exe, ram, cache, tb], out / (name + '-build.log'), 45)
            log = out / (name + '.log')
            run(['vvp', '-N', exe], log, 45)
            counts = {k: int(n) for k, n in re.findall(r'(checks|responses|merges|dual|both_ready|join_pop|errors)=(\d+)', log.read_text())}
            assert 'PASS ' in log.read_text() and counts['merges'] > 0 and counts['dual'] > 0 and counts['errors'] > 0
            result['tests'].append({'parameters': parameters, 'passed': True, 'counts': counts, 'log_sha256': digest(log)})
            print('PASS dual-MSHR', name, counts, flush=True)
        assert all(digest(Path(p)) == h for p, h in result['sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
