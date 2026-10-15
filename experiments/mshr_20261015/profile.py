#!/usr/bin/env python3
"""Measure MSHR occupancy and request latency without editing framework files."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FRAMEWORK = ROOT.parent/'RISC-V-CPU-2026'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--mshrs', type=int, choices=(1, 2), required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    source = out/'source'
    for name in ('rtl', 'verilog'):
        shutil.copytree(args.source/name, source/name)
    shutil.copyfile(HERE/'profile.h', out/'profile.h')
    harness = (FRAMEWORK/'scripts/sim.cpp').read_text()
    for old, new in (
        ('#include "Vstudent_top.h"', '#include "Vstudent_top.h"\n#include "profile.h"'),
        ('Vstudent_top top{&context};', 'Vstudent_top top{&context};\n        Profile profile;'),
        ('memory.step(top, latency);', 'profile.sample(top);\n            memory.step(top, latency);'),
        ('top.final();', 'profile.report();\n        top.final();')):
        assert harness.count(old) == 1
        harness = harness.replace(old, new)
    (out/'sim.cpp').write_text(harness)
    sys.path.insert(0, str(FRAMEWORK/'scripts'))
    from build import read_sources
    from fakeram import with_ram_source
    files = with_ram_source(read_sources(source/'verilog/filelist.f'))
    params = {'FE_WIDTH': 2, 'BE_WIDTH': 2, 'PHYS_REGS': 64, 'ROB_ENTRIES': 32,
              'RECOVERY_WIDTH': 4, 'ICACHE_SIZE_BYTES': 1024, 'ICACHE_NUM_SETS': 64,
              'ICACHE_NUM_WAYS': 1, 'DCACHE_SIZE_BYTES': 16384, 'DCACHE_NUM_SETS': 512,
              'DCACHE_NUM_WAYS': 2}
    if 'parameter DCACHE_MSHR_ENTRIES' in (source/'rtl/student_top.v').read_text():
        params['DCACHE_MSHR_ENTRIES'] = args.mshrs
    else:
        assert args.mshrs == 1
    guarded = [*files, *list((source/'rtl').glob('*.vh')), HERE/'profile.h', Path(__file__),
               out/'sim.cpp', FRAMEWORK/'scripts/sim.cpp', out/'profile.h']
    result = {'completed': False, 'passed': False, 'mshrs': args.mshrs, 'parameters': params,
              'source_sha256': {str(p): digest(p) for p in guarded}, 'cases': []}

    def run(command, log, seconds):
        command = ['timeout', '-k', '5', str(seconds), *map(str, command)]
        (log.with_suffix('.command.json')).write_text(json.dumps(command, indent=2)+'\n')
        with log.open('w') as stream:
            process = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        assert process.returncode == 0, log

    try:
        flags = '-std=c++17 -I'+str(out)+' -DCONFIG_MSHRS='+str(args.mshrs)
        command = ['verilator', '--cc', '--exe', '--build', '--assert', '--trace', '--public-flat-rw',
                   '-DRV32_TEST_WATCHDOG', '-Wall', '-Wno-fatal', '--top-module', 'student_top',
                   '--Mdir', out/'obj', '-o', out/'sim', '-j', '2', '-I'+str(source/'rtl'), '-CFLAGS', flags]
        command += ['-G'+k+'='+str(v) for k, v in params.items()]+files+[out/'sim.cpp']
        run(command, out/'build.log', 420)
        result['sim_sha256'] = digest(out/'sim')
        for case in sorted((ROOT.parent/'RISC-V-CPU-2026-Testcases').glob('perf_*')):
            expected = int((case/'expected.txt').read_text())
            run([out/'sim', case/'program.data', str(expected), '3000000', '10'], out/(case.name+'.log'), 60)
            log = (out/(case.name+'.log')).read_text()
            assert not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log), case.name
            match = re.search(r'^PASS cycles=(\d+) result=(\d+) expected=(\d+)$', log, re.M)
            profile = re.findall(r'^PROFILE (.*)$', log, re.M)
            assert match and len(profile) == 1 and int(match[2]) == int(match[3]) == expected
            data = json.loads(profile[0])
            instructions = json.loads((case/'metrics.json').read_text())['dynamic_instructions']
            counts = data['counts']
            assert counts['cycles'] == int(match[1]) and counts['retired'] == instructions-1
            assert sum(counts.get('mshr_occupancy_'+str(i), 0) for i in range(3)) == int(match[1])
            for kind in ('load', 'store'):
                assert sum(data[kind+'_latency'].values()) == counts['ram_'+kind+'_requests'] == counts['ram_'+kind+'_responses']
            result['cases'].append({'name': case.name, 'cycles': int(match[1]), 'profile': data,
                                    'log_sha256': digest(out/(case.name+'.log'))})
            print('PASS', args.mshrs, case.name, match[1], counts.get('merged_requests', 0), flush=True)
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
