#!/usr/bin/env python3
"""Freeze an area candidate and run bounded, unchanged official tools."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK = ROOT.parent / 'RISC-V-CPU-2026'
CASES = ROOT.parent / 'RISC-V-CPU-2026-Testcases'
sys.path.insert(0, str(ROOT / 'tools'))
from run_synthesis import configured_sources, validate_report
sys.path.insert(0, str(FRAMEWORK / 'scripts'))
from build import read_sources


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def run(command, log, seconds):
    command = ['timeout', '-k', '5', str(seconds), *map(str, command)]
    save(log.with_suffix('.command.json'), command)
    with log.open('w') as output:
        process = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    assert process.returncode == 0, log
    assert not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--fe', type=int, choices=(1, 2, 4), default=4)
    parser.add_argument('--be', type=int, choices=(1, 2, 4), default=4)
    parser.add_argument('--phys', type=int, default=64)
    parser.add_argument('--rob', type=int, default=32)
    parser.add_argument('--directory', type=int, default=0)
    parser.add_argument('--hints', type=int, default=8)
    parser.add_argument('--phase', choices=('prepare', 'screen', 'suite', 'ppa'), required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    if args.phase == 'prepare':
        out.mkdir(parents=True, exist_ok=False)
        for name in ('rtl', 'verilog'):
            shutil.copytree(args.source / name, out / 'source' / name)
        sources = read_sources(out / 'source/verilog/filelist.f')
        configured_sources(sources, (args.fe, args.be, args.phys, args.rob), out / 'input')
        top = out / 'input/student_top.v'
        text = top.read_text()
        for key, value in {'STORE_DIRECTORY_ENTRIES': args.directory, 'STORE_HINTS': args.hints}.items():
            text, count = re.subn(r'(parameter ' + key + r' = )\d+',
                                 lambda m: m[1] + str(value), text)
            assert count == 1
        top.write_text(text)
        dependencies = sources + list((out / 'source/rtl').glob('*.vh'))
        dependencies += list((out / 'input').glob('*')) + [Path(__file__)]
        dependencies += list((FRAMEWORK / 'scripts').glob('*.py'))
        dependencies += [FRAMEWORK / 'scripts/timing.tcl', FRAMEWORK / 'scripts/sim.cpp',
                         FRAMEWORK / 'scripts/ram/sram_fakeram.sv', ROOT / 'tools/build_configured.py']
        dependencies += list((ROOT / '.deps/asap7/lib').glob('*.lib'))
        dependencies += [ROOT / p for p in ('.deps/yosys/bin/yosys', '.deps/yosys/bin/yosys-abc',
                                           '.deps/opensta/bin/sta')]
        dependencies += [p for case in CASES.iterdir() for p in case.glob('*') if p.is_file()]
        save(out / 'snapshot.json', {
            'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
            'configuration': {'FE_WIDTH': args.fe, 'BE_WIDTH': args.be, 'PHYS_REGS': args.phys,
                              'ROB_ENTRIES': args.rob, 'STORE_DIRECTORY_ENTRIES': args.directory,
                              'STORE_HINTS': args.hints},
            'sha256': {str(p): digest(p) for p in dependencies}})
        return
    snapshot = json.loads((out / 'snapshot.json').read_text())
    def verify():
        assert all(digest(Path(p)) == h for p, h in snapshot['sha256'].items())
    verify()
    result = {'completed': False, 'passed': False, 'configuration': snapshot['configuration'],
              'snapshot_sha256': digest(out / 'snapshot.json')}
    try:
        if args.phase in ('screen', 'suite'):
            sim = out / 'official/sim'
            if not sim.exists():
                config = snapshot['configuration']
                run([sys.executable, '-B', ROOT / 'tools/build_configured.py',
                     '--framework', FRAMEWORK, '--filelist', out / 'input/filelist.f',
                     '--out', out / 'official', '--fe-width', config['FE_WIDTH'], '--be-width', config['BE_WIDTH'],
                     '--phys-regs', config['PHYS_REGS'], '--rob-entries', config['ROB_ENTRIES'],
                     '--jobs', '2'], out / 'build.log', 600)
            result.update(sim_sha256=digest(sim), cases=[])
            for case in sorted(CASES.iterdir()):
                if not (case / 'program.data').exists():
                    continue
                if args.phase == 'screen' and not case.name.startswith('perf_'):
                    continue
                expected = int((case / 'expected.txt').read_text())
                log = out / (args.phase + '-' + case.name + '.log')
                run([sim, case / 'program.data', expected, '30000000', '10'], log, 300)
                match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', log.read_text())
                assert match and int(match[2]) == int(match[3]) == expected, log
                row = {'name': case.name, 'cycles': int(match[1]), 'log_sha256': digest(log)}
                if case.name.startswith('perf_'):
                    n = json.loads((case / 'metrics.json').read_text())['dynamic_instructions']
                    row.update(dynamic_instructions=n, ipc=n / row['cycles'])
                result['cases'].append(row)
                print('PASS', case.name, row['cycles'], flush=True)
            perf = [row['ipc'] for row in result['cases'] if 'ipc' in row]
            assert len(perf) == 6
            assert len(result['cases']) == (6 if args.phase == 'screen' else 25)
            result['ipc_geomean'] = math.exp(sum(map(math.log, perf)) / len(perf))
        else:
            run([sys.executable, '-B', FRAMEWORK / 'scripts/synth.py', '--filelist',
                 out / 'input/filelist.f', '--out', out / 'ppa', '--mode', 'opt',
                 '--clock-period', '2.0', '--abc-driving-cell', 'INVx1_ASAP7_75t_R',
                 '--abc-load-ff', '5.0', '--yosys', ROOT / '.deps/yosys/bin/yosys',
                 '--abc', ROOT / '.deps/yosys/bin/yosys-abc', '--sta', ROOT / '.deps/opensta/bin/sta',
                 '--asap7-lib', ROOT / '.deps/asap7/lib'], out / 'ppa.log', 7200)
            report = json.loads((out / 'ppa/opt/report.json').read_text())
            validate_report(report, 'opt', 2.0)
            result['report'] = report
            print('PASS PPA', report['area']['area_um2'], report['timing']['estimated_fmax_mhz'], flush=True)
        verify()
        result.update(completed=True, passed=True)
    finally:
        save(out / (args.phase + '-results.json'), result)


if __name__ == '__main__':
    main()
