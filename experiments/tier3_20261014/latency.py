#!/usr/bin/env python3
"""Sweep external latency without treating diagnostic settings as scores."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT.parent/'RISC-V-CPU-2026-Testcases'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    hashes = {str(args.sim): digest(args.sim), str(Path(__file__)): digest(Path(__file__))}
    rows = []
    for latency in (1, 5, 20):
        row = {'latency': latency, 'cases': []}
        for case in sorted(CASES.glob('perf_*')):
            for name in ('program.data', 'expected.txt', 'metrics.json'):
                hashes[str(case/name)] = digest(case/name)
            expected = int((case/'expected.txt').read_text())
            instructions = json.loads((case/'metrics.json').read_text())['dynamic_instructions']
            command = ['timeout', '-k', '5', '30', str(args.sim.resolve()),
                       str(case/'program.data'), str(expected), '3000000', str(latency)]
            run = subprocess.run(command, capture_output=True, text=True)
            stem = args.out/(case.name+'-l'+str(latency))
            stem.with_suffix('.stdout').write_text(run.stdout)
            stem.with_suffix('.stderr').write_text(run.stderr)
            match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', run.stdout)
            assert run.returncode == 0 and match and int(match[2]) == int(match[3]) == expected
            profile = json.loads(re.search(r'^PROFILE (.*)$', run.stderr, re.M)[1])
            detail = json.loads(re.search(r'^DETAIL (.*)$', run.stderr, re.M)[1])
            cycles = int(match[1])
            counts = profile['counts']
            assert counts['cycles'] == cycles and counts['retired'] == instructions-1
            assert sum(v for k, v in counts.items() if k.startswith('partition_')) == cycles
            row['cases'].append({'case': case.name, 'cycles': cycles, 'ipc': instructions/cycles,
                'profile': profile, 'detail': detail, 'command': command,
                'stdout_sha256': digest(stem.with_suffix('.stdout')),
                'stderr_sha256': digest(stem.with_suffix('.stderr'))})
        row['geomean'] = math.exp(sum(math.log(c['ipc']) for c in row['cases'])/len(row['cases']))
        rows.append(row)
        print(latency, row['geomean'], flush=True)
    assert all(digest(Path(p)) == h for p, h in hashes.items())
    (args.out/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'input_sha256': hashes, 'unchanged': True, 'results': rows}, indent=2)+'\n')


if __name__ == '__main__':
    main()
