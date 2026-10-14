#!/usr/bin/env python3
"""Exercise posted store ownership and validated result bypasses with timeouts."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/deep-unit'


def run(command, name):
    command = ['timeout', '-k', '5', '30', *map(str, command)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    log = result.stdout + result.stderr
    (OUT / (name + '.log')).write_text(log)
    if result.returncode or re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log):
        raise RuntimeError(name + ': inspect ' + str(OUT / (name + '.log')))
    return log


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    files = list((ROOT / 'rtl').glob('*')) + list((ROOT / 'tb').glob('*.v')) + [Path(__file__)]
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}
    tests = []
    def test(top, sources, options=(), label=None, sv=False):
        label = label or top
        binary = OUT / label
        run(['iverilog', '-g2012' if sv else '-g2005', '-I', 'rtl', '-s', top,
             *options, '-o', binary, *sources, 'tb/' + top + '.v'], label + '-build')
        log = run(['vvp', '-N', binary], label)
        if 'PASS ' + top not in log:
            raise RuntimeError('missing PASS: ' + label)
        tests.append({'name': label, 'passed': True,
                      'log_sha256': hashlib.sha256(log.encode()).hexdigest()})
        print(log.strip().splitlines()[0], flush=True)
    wb = ['rtl/rv32_ranked_select.v', 'rtl/rv32_completion_writeback_network.v']
    for width in (1, 2, 4):
        test('rv32_result_bypass_tb', wb,
             ['-P', 'rv32_result_bypass_tb.BE_WIDTH=' + str(width),
              '-P', 'rv32_result_bypass_tb.SOURCE_COUNT=' + str(width+3)],
             'bypass-' + str(width))
    for width in (2, 4):
        test('rv32_result_bypass_rob_tb', wb + ['rtl/rv32_reorder_buffer.v',
             'rtl/rv32_physical_register_file.v'],
             ['-P', 'rv32_result_bypass_rob_tb.BE_WIDTH=' + str(width)], 'rob-bypass-' + str(width))
    for width in (1, 2, 4):
        test('rv32_load_store_queue_tb', ['rtl/rv32_load_store_queue.v'],
             ['-P', 'rv32_load_store_queue_tb.BE_WIDTH=' + str(width),
              '-P', 'rv32_load_store_queue_tb.POSTED_STORES=1',
              '-P', 'rv32_load_store_queue_tb.LOAD_FALLTHROUGH=1'], 'lsq-bypass-' + str(width))
    cache = ['../RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv',
             'rtl/rv32_l1_data_cache.v', 'tb/rv32_main_memory.v']
    for ways in (1, 2):
        for hints in (1, 4, 8, 16):
            test('rv32_cache_posted_random_tb', cache,
                 ['-P', 'rv32_cache_posted_random_tb.WAYS=' + str(ways),
                  '-P', 'rv32_cache_posted_random_tb.HINTS=' + str(hints)],
                 'cache-' + str(ways) + '-' + str(hints), sv=True)
    test('rv32_posted_store_tb', ['rtl/rv32_load_store_queue.v', *cache], sv=True)
    unchanged = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in hashes.items())
    record = {'completed': True, 'passed': unchanged, 'sources_unchanged': unchanged,
              'source_sha256': hashes, 'tests': tests}
    (OUT / 'results.json').write_text(json.dumps(record, indent=2) + '\n')
    if not unchanged:
        raise RuntimeError('sources changed while testing')
    print('PASS deep units: {} configurations'.format(len(tests)))


if __name__ == '__main__':
    main()
