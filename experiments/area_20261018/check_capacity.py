#!/usr/bin/env python3
"""Check the selected PRF56 non-power-of-two rename free-list capacity."""
from pathlib import Path

from measure import ROOT, run, save, digest


def main():
    out = ROOT / 'build/area-codex-20261018/capacity-unit'
    out.mkdir(parents=True, exist_ok=False)
    source = ROOT / 'rtl/rv32_rename_unit.v'
    tb = ROOT / 'tb/rv32_rename_unit_tb.v'
    result = {'completed': False, 'passed': False,
              'sha256': {str(p): digest(p) for p in (source, tb, Path(__file__))}, 'tests': []}
    try:
        for lanes in (1, 2, 4):
            name = f'p56-b{lanes}-r7'
            top = 'rv32_rename_unit_tb'
            binary = out / (name + '.vvp')
            run(['iverilog', '-g2005', '-Wall', '-s', top, '-o', binary,
                 '-P', f'{top}.PHYS_REGS=56', '-P', f'{top}.PHYS_REG_ADDR_WIDTH=6',
                 '-P', f'{top}.BE_WIDTH={lanes}', '-P', f'{top}.RECOVERY_WIDTH=7', source, tb],
                out / (name + '-build.log'), 30)
            log = out / (name + '.log')
            run(['vvp', '-N', binary], log, 30)
            assert 'PASS rv32_rename_unit PHYS_REGS=56' in log.read_text()
            result['tests'].append({'name': name, 'passed': True, 'log_sha256': digest(log)})
            print('PASS', name, flush=True)
        assert all(digest(Path(p)) == h for p, h in result['sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
