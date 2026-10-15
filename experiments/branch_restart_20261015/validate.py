#!/usr/bin/env python3
"""Run bounded project gates and retain their actual exit status and logs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    inputs = [*sorted((ROOT/'rtl').glob('*')), ROOT/'Makefile',
              ROOT/'tb/rv32_fetch_line_buffer_tb.v', ROOT/'tb/rv32_fetch_pipeline_tb.v']
    inputs = [p for p in inputs if p.is_file()]
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in inputs}, 'tests': []}
    commands = [
        ('unit', ['make', 'unit'], 1200),
        ('lint', ['make', 'lint'], 900),
        ('hum', [sys.executable, '-B', 'tools/test_hum.py', '--out', str(out/'hum')], 600),
        ('response-owner', [sys.executable, '-B', 'tools/test_response_owner.py',
                            '--out', str(out/'response-owner')], 300),
    ]
    try:
        for name, command, limit in commands:
            command = ['timeout', '-k', '5', str(limit), *command]
            log = out/(name+'.log')
            print('RUN', name, flush=True)
            with log.open('w') as output:
                run = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
            row = {'name': name, 'command': command, 'exit_code': run.returncode,
                   'log': str(log), 'log_sha256': digest(log)}
            result['tests'].append(row)
            assert run.returncode == 0, row
            print('PASS', name, flush=True)
        assert all(digest(Path(p)) == sha for p, sha in result['source_sha256'].items())
        # Fixed build directories are copied before another run can replace them.
        for name in ('int-rs-reuse-unit',):
            shutil.copytree(ROOT/'build'/name, out/(name+'-archive'))
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
