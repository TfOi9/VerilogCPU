#!/usr/bin/env python3
"""Compare generic resident Store rings with an independent RV32 interpreter."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from generate_core_vectors import immediate, store, branch, execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--selected', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sims = {'baseline256': ROOT/'build/store-directory-20261015/selected/official/sim',
            'selected': args.selected.resolve(), 'profiled': args.profile.resolve(),
            'no_confirmation': args.control.resolve()}
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    inputs = [*sims.values(), Path(__file__), ROOT/'tools/generate_core_vectors.py']
    hashes = {str(p): digest(p) for p in inputs}
    rows = []
    for lines in (32, 96, 160):
        words = [0x000100b7, immediate(3, 1, 1024), immediate(2, 0, 100), immediate(10, 0, 7)]
        words += [store(10, 1 if i < 128 else 3, 16*i if i < 128 else 16*i-1024) for i in range(lines)]
        loop = len(words)*4
        words += [store(10, 1 if i < 128 else 3, 16*i if i < 128 else 16*i-1024) for i in range(lines)]
        words += [immediate(2, 2, -1), branch(2, 0, loop-(len(words)+1)*4, 1)]
        words += [immediate(10, 1, 0, 2, 0x03), 0x80000fb7, store(10, 31, 0)]
        trace, expected = execute(words)
        image = out/(f'store-ring-{lines}.data')
        image.write_text('@00000000\n'+'\n'.join(
            ' '.join(f'{b:02x}' for b in w.to_bytes(4, 'little')) for w in words)+'\n')
        cycles = {}
        for name, sim in sims.items():
            command = ['timeout', '-k', '5', '30', str(sim), str(image), str(expected), '1000000', '10']
            run = subprocess.run(command, text=True, capture_output=True)
            log = out/(f'store-ring-{lines}-{name}.log')
            log.write_text(run.stdout+run.stderr)
            match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', run.stdout)
            assert run.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, log
            assert not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', run.stderr), log
            row = {'lines': lines, 'stage': name, 'instructions': len(trace),
                   'cycles': int(match[1]), 'expected': expected, 'passed': True,
                   'command': command, 'image_sha256': digest(image), 'log_sha256': digest(log)}
            if name in ('profiled', 'no_confirmation'):
                profile = json.loads(re.search(r'^PROFILE (.*)$', run.stderr, re.M)[1])
                assert profile['counts']['retired'] == len(trace)-1, log
                row['profile'] = profile
            rows.append(row)
            cycles[name] = row['cycles']
            print('PASS Store ring', lines, name, row['cycles'], flush=True)
        assert cycles['selected'] == cycles['profiled']
    assert all(digest(Path(p)) == h for p, h in hashes.items())
    (out/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'input_sha256': hashes, 'results': rows}, indent=2)+'\n')


if __name__ == '__main__':
    main()
