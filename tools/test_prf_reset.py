#!/usr/bin/env python3
"""Check PRF lazy reset across widths, capacities, collisions and reset reuse."""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
from run_synthesis import execute, digest


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def run(command, log, seconds):
    record = execute(list(map(str, command)), log, seconds)
    save(log.with_suffix('.command.json'), record)
    assert record['passed'], log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'rtl/rv32_physical_register_file.v')
    parser.add_argument('--out', type=Path, default=ROOT / 'build/prf-reset-unit')
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        out = out / ('run-' + str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    source = args.source.resolve()
    tb = ROOT / 'tb/rv32_physical_register_file_tb.v'
    result = {'completed': False, 'passed': False,
              'sha256': {str(p): digest(p) for p in (source, tb, Path(__file__))}, 'tests': []}
    try:
        for count in (33, 48, 56, 64, 96):
            width = (count - 1).bit_length()
            for lanes in (1, 2, 4):
                name = f'p{count}-b{lanes}'
                binary = out / (name + '.vvp')
                top = 'rv32_physical_register_file_tb'
                run(['iverilog', '-g2005', '-Wall', '-s', top, '-o', binary,
                     '-P', f'{top}.PHYS_REGS={count}', '-P', f'{top}.PHYS_REG_ADDR_WIDTH={width}',
                     '-P', f'{top}.BE_WIDTH={lanes}', source, tb], out / (name + '-build.log'), 30)
                log = out / (name + '.log')
                run(['vvp', '-N', binary], log, 30)
                assert 'PASS rv32_physical_register_file_tb' in log.read_text()
                result['tests'].append({'name': name, 'passed': True, 'log_sha256': digest(log)})
                print('PASS', name, flush=True)
        assert all(digest(Path(p)) == h for p, h in result['sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
