#!/usr/bin/env python3
"""Freeze one configuration and measure it with the unmodified official flow."""
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
FRAMEWORK = ROOT.parent/'RISC-V-CPU-2026'
CASES = ROOT.parent/'RISC-V-CPU-2026-Testcases'
sys.path.insert(0, str(ROOT/'tools'))
from run_synthesis import configured_sources, validate_report
sys.path.insert(0, str(FRAMEWORK/'scripts'))
from build import read_sources


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')


def run(command, log, seconds):
    command = ['timeout', '-k', '5', str(seconds), *map(str, command)]
    save(log.with_suffix('.command.json'), command)
    with log.open('w') as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    assert result.returncode == 0, log
    assert not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--phase', choices=('prepare', 'sim', 'ppa'), required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    if args.phase == 'prepare':
        out.mkdir(parents=True, exist_ok=False)
        source = out/'source'
        for name in ('rtl', 'verilog'):
            shutil.copytree(args.source/name, source/name)
        sources = read_sources(source/'verilog/filelist.f')
        filelist, projected = configured_sources(sources, (2, 2, 64, 32), out/'input')
        top = out/'input/student_top.v'
        text = top.read_text()
        for key, value in {'ICACHE_SIZE_BYTES': 1024, 'ICACHE_NUM_SETS': 64, 'ICACHE_NUM_WAYS': 1,
                           'DCACHE_SIZE_BYTES': 16384, 'DCACHE_NUM_SETS': 512, 'DCACHE_NUM_WAYS': 2}.items():
            text, count = re.subn(r'(parameter integer '+key+r' = )\d+', lambda m: m[1]+str(value), text)
            assert count == 1, key
        top.write_text(text)
        files = sources + list((source/'rtl').glob('*.vh')) + list((out/'input').glob('*'))
        files += [FRAMEWORK/'scripts'/n for n in ('synth.py', 'timing.tcl', 'build.py', 'sim.cpp', 'fakeram.py')]
        files += [FRAMEWORK/'scripts/ram/sram_fakeram.sv']
        save(out/'snapshot.json', {'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'framework_revision': subprocess.check_output(['git', '-C', str(FRAMEWORK), 'rev-parse', 'HEAD'], text=True).strip(),
            'source_sha256': {str(p): digest(p) for p in files}, 'configuration': {
                'FE_WIDTH': 2, 'BE_WIDTH': 2, 'PHYS_REGS': 64, 'ROB_ENTRIES': 32,
                'ICACHE_BYTES': 1024, 'ICACHE_WAYS': 1, 'DCACHE_BYTES': 16384, 'DCACHE_WAYS': 2}})
        print('PASS frozen', out, flush=True)
        return
    snapshot = json.loads((out/'snapshot.json').read_text())
    assert snapshot['framework_revision'] == '302f0cf3cccdaa5de084a2120e0d950c663e4cf5'
    assert all(digest(Path(p)) == h for p, h in snapshot['source_sha256'].items())
    record = {'completed': False, 'passed': False, 'snapshot_sha256': digest(out/'snapshot.json')}
    try:
        if args.phase == 'sim':
            run([sys.executable, '-B', ROOT/'tools/build_configured.py', '--framework', FRAMEWORK,
                 '--filelist', out/'input/filelist.f', '--out', out/'official', '--fe-width', '2',
                 '--be-width', '2', '--phys-regs', '64', '--rob-entries', '32', '--icache', '1024,1',
                 '--dcache', '16384,2', '--jobs', '2'], out/'build.log', 420)
            sim = out/'official/sim'
            record['sim_sha256'] = digest(sim)
            record['cases'] = []
            perf = []
            for case in sorted(CASES.iterdir()):
                if not (case/'program.data').exists():
                    continue
                expected = int((case/'expected.txt').read_text())
                log = out/(case.name+'.log')
                run([sim, case/'program.data', str(expected), '30000000', '10'], log, 120)
                match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', log.read_text())
                assert match and int(match[2]) == int(match[3]) == expected, log
                row = {'name': case.name, 'cycles': int(match[1]), 'log_sha256': digest(log),
                       'image_sha256': digest(case/'program.data'), 'expected_sha256': digest(case/'expected.txt')}
                if case.name.startswith('perf_'):
                    n = json.loads((case/'metrics.json').read_text())['dynamic_instructions']
                    row.update(dynamic_instructions=n, ipc=n/row['cycles'], metrics_sha256=digest(case/'metrics.json'))
                    perf.append(row['ipc'])
                record['cases'].append(row)
                print('PASS', case.name, row['cycles'], flush=True)
            assert len(perf) == 6 and len(record['cases']) == 25
            record['ipc_geomean'] = math.exp(sum(map(math.log, perf))/len(perf))
        else:
            run([sys.executable, '-B', FRAMEWORK/'scripts/synth.py', '--filelist', out/'input/filelist.f',
                 '--out', out/'ppa', '--mode', 'opt', '--clock-period', '2.0',
                 '--abc-driving-cell', 'INVx1_ASAP7_75t_R', '--abc-load-ff', '5.0',
                 '--yosys', ROOT/'.deps/yosys/bin/yosys', '--abc', ROOT/'.deps/yosys/bin/yosys-abc',
                 '--sta', ROOT/'.deps/opensta/bin/sta', '--asap7-lib', ROOT/'.deps/asap7/lib'], out/'ppa.log', 2400)
            report = json.loads((out/'ppa/opt/report.json').read_text())
            validate_report(report, 'opt', 2.0)
            assert report['abc_constraints'] == {'driving_cell': 'INVx1_ASAP7_75t_R', 'output_load_ff': 5.0}
            record['report'] = report
            record['artifact_sha256'] = {str(p): digest(p) for p in (out/'ppa/opt').iterdir() if p.is_file()}
            print('PASS PPA', report['area']['area_um2'], report['timing']['estimated_fmax_mhz'], flush=True)
        assert all(digest(Path(p)) == h for p, h in snapshot['source_sha256'].items())
        record.update(completed=True, passed=True)
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        save(out/(args.phase+'-results.json'), record)


if __name__ == '__main__':
    main()
