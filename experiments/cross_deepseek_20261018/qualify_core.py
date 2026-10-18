#!/usr/bin/env python3
"""Check the frozen candidate core with three independent retirement traces."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/area_20261018'))
from measure import digest, read_sources, run, save


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    config = json.loads((candidate / 'snapshot.json').read_text())['configuration']
    out = candidate / 'retirement'
    out.mkdir(parents=True, exist_ok=False)
    sources = [p for p in read_sources(candidate / 'input/filelist.f') if p.name not in (
        'student_top.v', 'rv32_l1_instruction_cache.v', 'rv32_l1_data_cache.v', 'rv32_l1_cache_axi_bridge.v')]
    tb = ROOT / 'tb/rv32_cpu_core_width_tb.v'
    files = sources + list((candidate / 'source/rtl').glob('*.vh')) + [tb, Path(__file__), ROOT / 'tools/generate_core_vectors.py']
    result = {'completed': False, 'passed': False, 'core_configuration': {
        **{k: config[k] for k in ('FE_WIDTH', 'BE_WIDTH', 'PHYS_REGS', 'ROB_ENTRIES')},
        'RECOVERY_WIDTH': 7}, 'sha256': {str(p): digest(p) for p in files}, 'tests': []}
    try:
        run(['verilator', '--binary', '--timing', '--trace', '--assert', '--language', '1364-2005',
             '-Wall', '-Wno-fatal', '-DRV32_TEST_WATCHDOG', '--top-module', 'rv32_cpu_core_width_tb',
             '-I' + str(candidate / 'source/rtl'), '--Mdir', out / 'obj', '-o', 'core_tb', '-j', '2',
             *['-G' + k + '=' + str(v) for k, v in result['core_configuration'].items()],
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
