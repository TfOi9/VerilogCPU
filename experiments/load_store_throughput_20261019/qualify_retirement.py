#!/usr/bin/env python3
"""Check ordered and tagged retirement at the selected PRF56 configuration."""
import argparse
import sys
from pathlib import Path
from measure import ROOT, read_sources, run, save, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sources = [p for p in read_sources(ROOT / 'verilog/filelist.f') if p.name not in (
        'student_top.v', 'rv32_l1_instruction_cache.v', 'rv32_l1_data_cache.v', 'rv32_l1_cache_axi_bridge.v')]
    benches = [ROOT / 'tb' / (name + '.v') for name in ('rv32_cpu_core_width_tb', 'rv32_cpu_core_tagged_tb')]
    files = sources + list((ROOT / 'rtl').glob('*.vh')) + benches + [Path(__file__), ROOT / 'tools/generate_core_vectors.py']
    result = {'completed': False, 'passed': False, 'configuration': {
        'FE_WIDTH': 4, 'BE_WIDTH': 4, 'PHYS_REGS': 56, 'ROB_ENTRIES': 32, 'RECOVERY_WIDTH': 7},
        'source_sha256': {str(p): digest(p) for p in files}, 'tests': []}
    seeds = (0x2401, 0x2402, 0x2403)
    try:
        for seed in seeds:
            run([sys.executable, ROOT / 'tools/generate_core_vectors.py', '--out', out / str(seed), '--seed', seed],
                out / (str(seed) + '-generate.log'), 30)
        for tb in benches:
            name = tb.stem
            binary = out / name / 'core_tb'
            run(['verilator', '--binary', '--timing', '--trace', '--assert', '--language', '1364-2005',
                 '-Wall', '-Wno-fatal', '-DRV32_TEST_WATCHDOG', '--top-module', name,
                 '-Irtl', '--Mdir', binary.parent, '-o', 'core_tb', '-j', '2',
                 '-GFE_WIDTH=4', '-GBE_WIDTH=4', '-GPHYS_REGS=56', '-GROB_ENTRIES=32', '-GRECOVERY_WIDTH=7',
                 *sources, tb], out / (name + '-build.log'), 300)
            for seed in seeds:
                vectors = out / str(seed)
                log = out / (name + '-' + str(seed) + '.log')
                run([binary, '+PROGRAM=' + str(vectors.with_suffix('.words')),
                     '+TRACE=' + str(vectors.with_suffix('.trace')),
                     '+EXPECTED=' + vectors.with_suffix('.result').read_text().strip(), '+SEED=' + str(seed)], log, 30)
                assert 'PASS core ' in log.read_text(), log
                result['tests'].append({'bench': name, 'seed': seed, 'passed': True, 'log_sha256': digest(log)})
                print('PASS retirement', name, seed, flush=True)
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
