#!/usr/bin/env python3
"""Compare mixed store/load workloads against an independent architectural model."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/return-path-20261014/probes'
sys.path.insert(0, str(ROOT/'tools'))
from generate_core_vectors import branch, execute, immediate, register, store


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--measurement', required=True)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=False)
    rows = []
    for kind in ('store-disjoint-load-chain', 'store-alias-load-chain', 'store-byte-disjoint-load'):
        words = [0x000100b7, 0x000102b7, immediate(2, 0, 200),
                 immediate(3, 0, 85), store(1, 1, 0)]
        loop = len(words)*4
        if kind == 'store-byte-disjoint-load':
            for _ in range(24):
                words += [store(3, 1, 0, 0), immediate(4, 1, 1, 4, 0x03), register(1, 5, 4)]
        else:
            for _ in range(32):
                words += [store(1, 1, 4 if kind == 'store-disjoint-load-chain' else 0),
                          immediate(1, 1, 0, 2, 0x03)]
        words += [immediate(2, 2, -1), branch(2, 0, loop-(len(words)+1)*4, 1)]
        words += [immediate(10, 1, 0, 4, 0x03) if kind == 'store-byte-disjoint-load'
                  else immediate(10, 1, 0), 0x80000fb7, store(10, 31, 0)]
        trace, expected = execute(words)
        image = OUT/(kind+'.data')
        image.write_text('@00000000\n'+'\n'.join(' '.join(f'{b:02x}'
            for b in w.to_bytes(4, 'little')) for w in words)+'\n')
        for stage in ('baseline', args.measurement):
            sim = ROOT/'build/return-path-20261014'/stage/'official/sim'
            command = ['timeout', '-k', '5', '60', str(sim), str(image), str(expected), '1000000', '10']
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            log = OUT/(stage+'-'+kind+'.log')
            log.write_text(result.stdout+result.stderr)
            match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', result.stdout)
            assert result.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, log
            cycles = int(match[1])
            rows.append({'stage': stage, 'probe': kind, 'passed': True, 'cycles': cycles,
                'instructions': len(trace), 'ipc': len(trace)/cycles, 'expected': expected,
                'command': command, 'sim_sha256': digest(sim), 'image': str(image),
                'image_sha256': digest(image), 'log': str(log), 'log_sha256': digest(log)})
            print('PASS', stage, kind, cycles, flush=True)
    (OUT/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'reference': 'tools/generate_core_vectors.py execute',
        'reference_sha256': digest(ROOT/'tools/generate_core_vectors.py'),
        'runner_sha256': digest(Path(__file__)), 'results': rows}, indent=2)+'\n')


if __name__ == '__main__':
    main()
