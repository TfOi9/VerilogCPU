#!/usr/bin/env python3
"""Check retirement traces at the selected non-power-of-two PRF capacity."""
from pathlib import Path
import sys

from measure import ROOT, FRAMEWORK, read_sources, run, save, digest


def main():
    out = ROOT / 'build/area-codex-20261018/selected-retirement'
    out.mkdir(parents=True, exist_ok=False)
    sources = [p for p in read_sources(ROOT / 'verilog/filelist.f') if p.name not in (
        'student_top.v', 'rv32_l1_instruction_cache.v', 'rv32_l1_data_cache.v', 'rv32_l1_cache_axi_bridge.v')]
    tb = ROOT / 'tb/rv32_cpu_core_width_tb.v'
    files = sources + list((ROOT / 'rtl').glob('*.vh')) + [tb, Path(__file__), ROOT / 'tools/generate_core_vectors.py']
    result = {'completed': False, 'passed': False, 'configuration': {
        'FE_WIDTH': 2, 'BE_WIDTH': 2, 'PHYS_REGS': 56, 'ROB_ENTRIES': 32, 'RECOVERY_WIDTH': 7},
        'sha256': {str(p): digest(p) for p in files}, 'tests': []}
    try:
        run(['verilator', '--binary', '--timing', '--trace', '--assert', '--language', '1364-2005',
             '-Wall', '-Wno-fatal', '-DRV32_TEST_WATCHDOG', '--top-module', 'rv32_cpu_core_width_tb',
             '-Irtl', '--Mdir', out / 'obj', '-o', 'core_tb', '-j', '2',
             '-GFE_WIDTH=2', '-GBE_WIDTH=2', '-GPHYS_REGS=56', '-GROB_ENTRIES=32', '-GRECOVERY_WIDTH=7',
             *sources, tb], out / 'build.log', 300)
        for seed in (0x2401, 0x2402, 0x2403):
            vectors = out / str(seed)
            run([sys.executable, ROOT / 'tools/generate_core_vectors.py', '--out', vectors, '--seed', seed],
                out / (str(seed) + '-generate.log'), 30)
            log = out / (str(seed) + '.log')
            run([out / 'obj/core_tb', '+PROGRAM=' + str(vectors.with_suffix('.words')),
                 '+TRACE=' + str(vectors.with_suffix('.trace')),
                 '+EXPECTED=' + vectors.with_suffix('.result').read_text().strip(), '+SEED=' + str(seed)], log, 30)
            assert 'PASS ' in log.read_text()
            result['tests'].append({'seed': seed, 'passed': True, 'log_sha256': digest(log)})
            print('PASS retirement', seed, flush=True)
        assert all(digest(Path(p)) == h for p, h in result['sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
