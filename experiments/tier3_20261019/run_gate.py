#!/usr/bin/env python3
"""Run one bounded acceptance gate and preserve exit status and live-source hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--seconds', type=int, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    command = args.command[1:] if args.command and args.command[0] == '--' else args.command
    assert command and args.seconds > 0
    inputs = [ROOT/'Makefile']
    for directory in ('rtl', 'tb', 'tools'):
        inputs += [p for p in (ROOT/directory).rglob('*') if p.is_file() and p.suffix in ('.v', '.vh', '.py')]
    inputs += [p for p in (ROOT/'experiments/tier3_20261019').glob('*.py')]
    before = {str(p): digest(p) for p in inputs}
    result = {'completed': False, 'passed': False, 'source_sha256': before,
              'command': ['timeout', '-k', '5', str(args.seconds), *command], 'wall_timeout_seconds': args.seconds}
    report = out/(args.name+'.exit.json')
    assert not report.exists(), report
    report.write_text(json.dumps(result, indent=2)+'\n')
    started = time.monotonic()
    with (out/(args.name+'.log')).open('w') as log:
        p = subprocess.run(result['command'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    result['elapsed_seconds'] = time.monotonic()-started
    result['returncode'] = p.returncode
    result['sources_unchanged'] = all(digest(Path(name)) == h for name, h in before.items())
    result['log_sha256'] = digest(out/(args.name+'.log'))
    result['completed'] = True
    result['passed'] = p.returncode == 0 and result['sources_unchanged']
    report.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: result[k] for k in ('completed', 'passed', 'returncode', 'sources_unchanged', 'elapsed_seconds')}), flush=True)
    raise SystemExit(not result['passed'])


if __name__ == '__main__':
    main()
