#!/usr/bin/env python3
"""Check RS slot reuse and independent cycle models on frozen candidates."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variants', nargs='+', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    inputs = {}
    tests = []

    def run(command, name):
        command = ['timeout', '-k', '5', '45', *map(str, command)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        log = out/(name+'.log')
        log.write_text(result.stdout+result.stderr)
        (out/(name+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
        assert result.returncode == 0 and not re.search(r'(?m)^(FAIL|ERROR)\b', log.read_text()), log
        return log

    for variant in args.variants:
        rtl = ROOT/'build/return-path-20261014'/variant/'source/rtl'
        files = [rtl/'rv32_ranked_select.v', rtl/'rv32_integer_reservation_station.v']
        headers = [rtl/'rv32im_defs.vh']
        for width in (1, 2, 4):
            for rob in (16, 32, 64):
                top = 'rv32_int_rs_reuse_tb'
                name = f'{variant}-reuse-w{width}-r{rob}'
                tb = ROOT/'tb'/(top+'.v')
                inputs.update({str(p): digest(p) for p in files+headers+[tb]})
                binary = out/name
                run(['iverilog', '-g2005', '-I', rtl, '-s', top, '-P', f'{top}.BE_WIDTH={width}',
                    '-P', f'{top}.ROB_ENTRIES={rob}', '-P', f'{top}.ROB_INDEX_WIDTH={rob.bit_length()-1}',
                    '-o', binary, *files, tb], name+'-build')
                log = run(['vvp', '-N', binary], name)
                match = re.search(r'PASS RS reuse .* checks=(\d+)', log.read_text())
                assert match, log
                tests.append({'variant': variant, 'name': name, 'passed': True,
                    'checks': int(match[1]), 'log': str(log), 'log_sha256': digest(log)})
                print('PASS', name, flush=True)
            entries, phys, rob = {1: (4, 48, 16), 2: (8, 64, 32), 4: (16, 96, 64)}[width]
            for seed in (8201, 8202, 8203):
                name = f'{variant}-model-w{width}-seed{seed}'
                vectors = out/(name+'.txt')
                generator = ROOT/'tools/generate_int_rs_vectors.py'
                run([sys.executable, '-B', generator, vectors, '--entries', entries, '--width', width,
                    '--phys-regs', phys, '--rob-entries', rob, '--cycles', '1500', '--seed', seed], name+'-generate')
                top = 'rv32_integer_reservation_station_tb'
                tb = ROOT/'tb'/(top+'.v')
                inputs.update({str(p): digest(p) for p in files+headers+[tb, generator]})
                binary = out/name
                parameters = {'BE_WIDTH': width, 'INT_RS_ENTRIES': entries,
                    'INT_RS_INDEX_WIDTH': (entries-1).bit_length(), 'PHYS_REGS': phys,
                    'PHYS_REG_ADDR_WIDTH': (phys-1).bit_length(), 'ROB_ENTRIES': rob,
                    'ROB_INDEX_WIDTH': (rob-1).bit_length()}
                options = [x for key, value in parameters.items() for x in ('-P', f'{top}.{key}={value}')]
                run(['iverilog', '-g2005', '-I', rtl, '-s', top, *options, '-o', binary, *files, tb], name+'-build')
                log = run(['vvp', '-N', binary, '+VECTOR_FILE='+str(vectors)], name)
                match = re.search(r'PASS rv32_integer_reservation_station .* vectors=1500 tests=(\d+)', log.read_text())
                assert match, log
                tests.append({'variant': variant, 'name': name, 'passed': True,
                    'checks': int(match[1]), 'vector_sha256': digest(vectors),
                    'log': str(log), 'log_sha256': digest(log)})
                print('PASS', name, flush=True)
    assert all(digest(Path(p)) == sha for p, sha in inputs.items())
    (out/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'sources_unchanged': True, 'source_sha256': inputs, 'tests': tests}, indent=2)+'\n')


if __name__ == '__main__':
    main()
