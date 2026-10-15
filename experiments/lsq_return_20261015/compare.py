#!/usr/bin/env python3
"""Compare memory RS cycle behavior against the immutable input revision."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = 'bcd3f31'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    reference = out/'reference.v'
    original = subprocess.check_output(['git', 'show', BASE+':rtl/rv32_memory_reservation_station.v'], cwd=ROOT).decode()
    reference.write_text(original.replace('module rv32_memory_reservation_station #(',
        'module rv32_memory_reservation_station_reference #(', 1))
    sources = [ROOT/'rtl/rv32_memory_reservation_station.v',
               ROOT/'tb/rv32_memory_rs_equivalence_tb.v', reference, Path(__file__)]
    result = {'completed': False, 'passed': False,
              'reference_revision': subprocess.check_output(['git', 'rev-parse', BASE], cwd=ROOT).decode().strip(),
              'source_sha256': {str(p): digest(p) for p in sources}, 'tests': []}
    configurations = [(be, rob, 8, kind) for be in (1, 2, 4) for rob in (4, 5, 6) for kind in (0, 1)]
    configurations += [(be, 5, entries, kind) for be in (1, 4) for entries in (4, 16) for kind in (0, 1)]
    try:
        for number, (be, rob, entries, kind) in enumerate(configurations):
            label = f'be{be}-rob{1<<rob}-rs{entries}-store{kind}'
            top = 'rv32_memory_rs_equivalence_tb'
            parameters = {'BE_WIDTH': be, 'ROB_INDEX_WIDTH': rob, 'RS_ENTRIES': entries,
                          'RS_INDEX_WIDTH': entries.bit_length()-1, 'IS_STORE': kind, 'SEED': 9217+number}
            options = [v for k, n in parameters.items() for v in ('-P', top+'.'+k+'='+str(n))]
            commands = [
                ['iverilog', '-g2005', '-s', top, *options, '-o', str(out/label), *map(str, sources[:3])],
                ['vvp', '-N', str(out/label)]]
            for phase, command in zip(('build', 'run'), commands):
                command = ['timeout', '-k', '5', '60', *command]
                run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
                log = out/(label+'-'+phase+'.log')
                log.write_text(run.stdout+run.stderr)
                (out/(label+'-'+phase+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
                assert run.returncode == 0 and not re.search(r'(?m)^(ERROR|FAIL)\b', log.read_text()), log
            checks = re.search(r'^PASS memory RS equivalence checks=(\d+)', log.read_text(), re.M)
            assert checks, log
            result['tests'].append({'name': label, 'parameters': parameters, 'passed': True,
                                    'checks': int(checks[1]), 'log': str(log), 'log_sha256': digest(log)})
            print('PASS', label, checks[1], flush=True)
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
