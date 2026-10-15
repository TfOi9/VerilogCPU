#!/usr/bin/env python3
"""Check late Store proofs, ownership and three-cycle hit timing."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'build/store-confirm-unit')
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        out = out/('run-'+str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    ram = ROOT.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'
    sources = [ram, ROOT/'rtl/rv32_l1_data_cache.v', ROOT/'rtl/rv32_load_store_queue.v',
               ROOT/'rtl/rv32im_defs.vh', Path(__file__)]
    sources += [ROOT/'tb'/n for n in ('rv32_store_directory_tb.v', 'rv32_cache_hum_tb.v',
                'rv32_posted_store_tb.v', 'rv32_main_memory.v', 'rv32_store_confirm_tb.v')]
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in sources}, 'tests': []}

    def test(top, label, parameters, extra=()):
        exe = out/label
        options = [v for k, n in parameters.items() for v in ('-P', top+'.'+k+'='+str(n))]
        commands = [
            ['iverilog', '-g2012', '-I', ROOT/'rtl', '-s', top, *options, '-o', exe,
             ram, ROOT/'rtl/rv32_l1_data_cache.v', ROOT/'rtl/rv32_load_store_queue.v',
             *extra, ROOT/'tb'/(top+'.v')],
            ['vvp', '-N', exe]]
        for phase, command in zip(('build', 'run'), commands):
            command = ['timeout', '-k', '5', '30', *map(str, command)]
            process = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            log = out/(label+'-'+phase+'.log')
            log.write_text(process.stdout+process.stderr)
            (out/(label+'-'+phase+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
            assert process.returncode == 0 and not re.search(
                r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log
        assert 'PASS ' in log.read_text(), log
        counts = {k: int(n) for k, n in re.findall(r'(checks|confirmations)=(\d+)', log.read_text())}
        result['tests'].append({'name': label, 'parameters': parameters, 'passed': True,
                                **counts, 'log_sha256': digest(log)})
        print('PASS', label, counts, flush=True)

    try:
        for ways in (1, 2, 3, 4):
            for directory in (1, 2, 8, 64):
                for nb in (0, 1):
                    test('rv32_store_directory_tb', f'directed-{ways}-{directory}-{nb}',
                         {'WAYS': ways, 'DIRECTORY': directory, 'NONBLOCKING': nb, 'LATE_CONFIRM': 1})
        for directory in (64, 128, 256):
            test('rv32_store_directory_tb', f'large-{directory}',
                 {'WAYS': 2, 'DIRECTORY': directory, 'SETS': 512, 'NONBLOCKING': 1, 'LATE_CONFIRM': 1})
        for ways in (1, 2):
            for directory in (1, 2, 64):
                for seed in (1, 2, 7, 42):
                    test('rv32_cache_hum_tb', f'hum-{ways}-{directory}-{seed}',
                         {'WAYS': ways, 'DIRECTORY': directory, 'SEED': seed, 'LATE_CONFIRM': 1})
        test('rv32_posted_store_tb', 'integration', {'DIRECTORY': 1, 'LATE_CONFIRM': 1},
             [ROOT/'tb/rv32_main_memory.v'])
        for recover in (0, 1, 2, 3):
            test('rv32_store_confirm_tb', f'identity-{recover}', {'RECOVER_CONFIRM': recover})
        assert sum(row.get('confirmations', 0) for row in result['tests']) > 0
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS Store confirmation', len(result['tests']), 'configurations', out, flush=True)


if __name__ == '__main__':
    main()
