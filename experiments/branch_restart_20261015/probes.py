#!/usr/bin/env python3
"""Check generic alternating and load-dependent branches with an independent reference."""
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
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    out = root/'probes'
    out.mkdir(exist_ok=False)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    rows = []
    for name in ('alternating-branch', 'load-dependent-branch'):
        words = [immediate(1, 0, 200), immediate(2, 0, 0), immediate(10, 0, 0), 0x00010237]
        loop = len(words)*4
        words.append(immediate(2, 2, 1, 4))
        operand = 2
        if name == 'load-dependent-branch':
            words.extend([store(2, 4, 0), immediate(3, 4, 0, 2, 3)])
            operand = 3
        words.extend([branch(operand, 0, 8), immediate(10, 10, 1), immediate(1, 1, -1)])
        words.append(branch(1, 0, loop-len(words)*4, 1))
        words.extend([0x80000fb7, store(10, 31, 0)])
        trace, expected = execute(words)
        image = out/(name+'.data')
        image.write_text('@00000000\n'+'\n'.join(' '.join(f'{b:02x}' for b in w.to_bytes(4, 'little'))
                                                   for w in words)+'\n')
        for stage in ('baseline', 'selected'):
            sim = root/stage/'official/sim'
            command = ['timeout', '-k', '5', '30', str(sim), str(image), str(expected), '1000000', '10']
            run = subprocess.run(command, text=True, capture_output=True)
            log = out/(stage+'-'+name+'.log')
            log.write_text(run.stdout+run.stderr)
            match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', run.stdout)
            assert run.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, log
            row = {'probe': name, 'stage': stage, 'passed': True, 'cycles': int(match[1]),
                   'dynamic_instructions': len(trace), 'expected': expected, 'command': command,
                   'image': str(image), 'image_sha256': digest(image), 'sim_sha256': digest(sim),
                   'log': str(log), 'log_sha256': digest(log)}
            rows.append(row)
            print('PASS', stage, name, row['cycles'], flush=True)
    (out/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'reference_sha256': digest(ROOT/'tools/generate_core_vectors.py'),
        'runner_sha256': digest(Path(__file__)), 'results': rows}, indent=2)+'\n')


if __name__ == '__main__':
    main()
