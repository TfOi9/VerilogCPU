#!/usr/bin/env python3
"""Run focused static and Store protocol checks on the selected frozen input."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/area_20261018'))
from measure import FRAMEWORK, digest, read_sources, run, save


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    config = json.loads((candidate / 'snapshot.json').read_text())['configuration']
    out = candidate / 'focused'
    out.mkdir(parents=True, exist_ok=False)
    sources = read_sources(candidate / 'input/filelist.f')
    raw_sources = read_sources(candidate / 'source/verilog/filelist.f')
    ram = FRAMEWORK / 'scripts/ram/sram_fakeram.sv'
    include = candidate / 'source/rtl'
    files = sources + raw_sources + list(include.glob('*.vh')) + [ram, Path(__file__)]
    files += [ROOT / 'tb' / (name + '.v') for name in (
        'rv32_store_directory_tb', 'rv32_cache_posted_random_tb', 'rv32_cache_hum_tb',
        'rv32_posted_store_tb', 'rv32_main_memory')]
    result = {'completed': False, 'passed': False, 'configuration': config,
              'sha256': {str(p): digest(p) for p in files}, 'tests': []}

    def check(name, command, seconds=60):
        log = out / (name + '.log')
        run(command, log, seconds)
        result['tests'].append({'name': name, 'passed': True, 'log_sha256': digest(log)})
        print('PASS', name, flush=True)

    try:
        binary = out / 'top.vvp'
        check('verilog-2005', ['iverilog', '-g2005', '-D', 'SYNTHESIS', '-I', include,
                              '-s', 'student_top', '-o', binary, ram, *sources])
        check('startup', ['vvp', '-N', binary], 30)
        check('verilator', ['verilator', '--lint-only', '--language', '1364-2005',
              '+1800-2012ext+sv', '-Wall', '-Wno-TIMESCALEMOD', '-Wno-BLKSEQ',
              '-Wno-DECLFILENAME', '-Wno-PINCONNECTEMPTY', '-Wno-UNUSEDSIGNAL',
              '--top-module', 'student_top', '-I' + str(include),
              *['-G' + k + '=' + str(v) for k, v in config.items()], ram, *raw_sources])
        directory = config['STORE_DIRECTORY_ENTRIES']
        if directory:
            for name, parameters, extra in (
                ('rv32_store_directory_tb', {'WAYS': 2, 'DIRECTORY': directory, 'SETS': 512, 'NONBLOCKING': 1, 'LATE_CONFIRM': 1}, []),
                ('rv32_cache_posted_random_tb', {'WAYS': 2, 'DIRECTORY': directory}, ['rv32_main_memory']),
                ('rv32_posted_store_tb', {'DIRECTORY': directory, 'LATE_CONFIRM': 0}, ['rv32_load_store_queue', 'rv32_main_memory']),
                *[('rv32_cache_hum_tb', {'WAYS': 2, 'DIRECTORY': directory, 'SEED': seed, 'LATE_CONFIRM': 1}, [])
                  for seed in (1, 2, 7, 42)]):
                label = name + '-' + str(parameters.get('SEED', 0))
                exe = out / label
                extra_files = [(candidate / 'input' if p == 'rv32_load_store_queue' else ROOT / 'tb') / (p + '.v') for p in extra]
                options = [item for key, value in parameters.items() for item in ('-P', name + '.' + key + '=' + str(value))]
                check(label + '-build', ['iverilog', '-g2012', '-I', include, '-s', name,
                      *options, '-o', exe, ram, candidate / 'input/rv32_l1_data_cache.v',
                      *extra_files, ROOT / 'tb' / (name + '.v')])
                check(label, ['vvp', '-N', exe], 30)
                assert 'PASS ' in (out / (label + '.log')).read_text()
        assert all(digest(Path(p)) == h for p, h in result['sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
