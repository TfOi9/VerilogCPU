#!/usr/bin/env python3
"""Check Store residency identity, ownership and fallback with bounded runs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'build/store-directory-unit')
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        out = out/('run-'+str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    ram = ROOT.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'
    cache = ROOT/'rtl/rv32_l1_data_cache.v'
    files = [ram, cache, Path(__file__), ROOT/'tb/rv32_store_directory_tb.v',
             ROOT/'tb/rv32_cache_hum_tb.v', ROOT/'tb/rv32_cache_posted_random_tb.v',
             ROOT/'tb/rv32_main_memory.v', ROOT/'tb/rv32_posted_store_tb.v',
             ROOT/'rtl/rv32_load_store_queue.v', ROOT/'rtl/rv32im_defs.vh']
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in files}, 'tests': []}

    def run(command, name, reject=False):
        command = ['timeout', '-k', '5', '30', *map(str, command)]
        process = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        log = out/(name+'.log')
        log.write_text(process.stdout+process.stderr)
        (out/(name+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
        if reject:
            assert process.returncode == 1 and 'ERROR invalid Store directory parameters' in log.read_text(), log
        else:
            assert process.returncode == 0 and not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log
        return log

    def test(top, label, parameters, extra=()):
        exe = out/label
        options = [option for key, value in parameters.items()
                   for option in ['-P', top+'.'+key+'='+str(value)]]
        run(['iverilog', '-g2012', '-I', ROOT/'rtl', '-s', top, *options, '-o', exe,
             ram, cache, *extra, ROOT/'tb'/(top+'.v')], label+'-build')
        log = run(['vvp', '-N', exe], label)
        assert 'PASS ' in log.read_text(), log
        checks = re.search(r'checks=(\d+)', log.read_text())
        result['tests'].append({'name': label, 'parameters': parameters,
                               'passed': True, 'checks': int(checks[1]) if checks else None,
                               'log': str(log), 'log_sha256': digest(log)})
        print('PASS', label, flush=True)

    try:
        for ways in (1, 2, 3, 4):
            for directory in (1, 2, 8, 64):
                for nonblocking in (0, 1):
                    test('rv32_store_directory_tb', f'directed-{ways}-{directory}-{nonblocking}',
                         {'WAYS': ways, 'DIRECTORY': directory, 'NONBLOCKING': nonblocking})
        for directory in (32, 64, 128, 256):
            test('rv32_store_directory_tb', f'large-2-{directory}',
                 {'WAYS': 2, 'DIRECTORY': directory, 'SETS': 512, 'NONBLOCKING': 1})
        for ways in (1, 2):
            for directory in (1, 2, 64):
                for seed in (1, 2, 7, 42):
                    test('rv32_cache_hum_tb', f'hum-{ways}-{directory}-{seed}',
                         {'WAYS': ways, 'DIRECTORY': directory, 'SEED': seed})
                test('rv32_cache_posted_random_tb', f'random-{ways}-{directory}',
                     {'WAYS': ways, 'DIRECTORY': directory}, [ROOT/'tb/rv32_main_memory.v'])
        for directory in (1, 2, 64):
            test('rv32_posted_store_tb', f'ownership-{directory}', {'DIRECTORY': directory},
                 [ROOT/'rtl/rv32_load_store_queue.v', ROOT/'tb/rv32_main_memory.v'])
        for directory in (-1, 3):
            label = f'reject-{directory}'
            exe = out/label
            run(['iverilog', '-g2012', '-s', 'rv32_store_directory_tb', '-P',
                 f'rv32_store_directory_tb.DIRECTORY={directory}', '-o', exe,
                 ram, cache, ROOT/'tb/rv32_store_directory_tb.v'], label+'-build')
            log = run(['vvp', '-N', exe], label, reject=True)
            result['tests'].append({'name': label, 'passed': True, 'expected_rejection': True,
                                   'log': str(log), 'log_sha256': digest(log)})
        result['sources_unchanged'] = all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        assert result['sources_unchanged']
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS Store directory', len(result['tests']), 'configurations', out, flush=True)


if __name__ == '__main__':
    main()
