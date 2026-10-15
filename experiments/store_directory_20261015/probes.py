#!/usr/bin/env python3
"""Check generic resident Store rings against an architectural reference."""
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


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    stages = {
        'baseline': (ROOT/'build/branch-restart-20261015/selected/official/sim',
                     ROOT/'build/next-optimization-20261015/sensitivity/baseline/sim'),
        'selected': (ROOT/'build/store-directory-20261015/selected/official/sim',
                     ROOT/'build/store-directory-20261015/profile-final/be2-dir256/sim'),
    }
    hashes = {str(p): digest(p) for pair in stages.values() for p in pair}
    hashes[str(ROOT/'tools/generate_core_vectors.py')] = digest(ROOT/'tools/generate_core_vectors.py')
    hashes[str(Path(__file__))] = digest(Path(__file__))
    rows = []
    for lines in (32, 64, 96):
        words = [0x000100b7, immediate(2, 0, 200), immediate(10, 0, 7)]
        words += [store(10, 1, 16*i) for i in range(lines)]
        loop = len(words)*4
        words += [store(10, 1, 16*i) for i in range(lines)]
        words += [immediate(2, 2, -1)]
        words += [branch(2, 0, loop-len(words)*4, 1)]
        words += [immediate(10, 1, 0, 2, 0x03), 0x80000fb7, store(10, 31, 0)]
        trace, expected = execute(words)
        image = out/(f'store-ring-{lines}.data')
        image.write_text('@00000000\n'+'\n'.join(
            ' '.join(f'{b:02x}' for b in w.to_bytes(4, 'little')) for w in words)+'\n')
        for stage, sims in stages.items():
            cycles = []
            for mode, sim in zip(('official', 'profiled'), sims):
                command = ['timeout', '-k', '5', '30', str(sim), str(image), str(expected), '1000000', '10']
                result = subprocess.run(command, text=True, capture_output=True)
                log = out/(f'store-ring-{lines}-{stage}-{mode}.log')
                log.write_text(result.stdout+result.stderr)
                match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', result.stdout)
                assert result.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, log
                assert not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', result.stderr), log
                row = {'lines': lines, 'stage': stage, 'mode': mode, 'passed': True,
                       'instructions': len(trace), 'expected': expected, 'cycles': int(match[1]),
                       'command': command, 'image_sha256': digest(image), 'log_sha256': digest(log)}
                if mode == 'profiled':
                    profile = json.loads(re.search(r'^PROFILE (.*)$', result.stderr, re.M)[1])
                    assert profile['counts']['retired'] == len(trace)-1
                    row['profile'] = profile
                rows.append(row)
                cycles.append(row['cycles'])
            assert cycles[0] == cycles[1]
            print('PASS Store ring', lines, stage, cycles[0], flush=True)
    assert all(digest(Path(p)) == h for p, h in hashes.items())
    (out/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
                                               'input_sha256': hashes, 'results': rows}, indent=2)+'\n')


if __name__ == '__main__':
    main()
