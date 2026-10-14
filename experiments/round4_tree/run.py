#!/usr/bin/env python3
"""Run independent full regressions, profiled programs, or official mappings."""
import argparse
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import re
import sys
from stage import ROOT, OUT, VARIANTS, CONFIGS, stage, verify, digest

# Use the previous harness without shadowing this script's module name.
spec = importlib.util.spec_from_file_location('round2_bench', ROOT/'experiments/round2_20261013/run.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
bench.OUT = OUT
execute = bench.execute


def unit(variant):
    base = OUT/variant
    execute(['make', '--no-print-directory', '-f', base/'Makefile.unit', 'unit'], base/'unit.log', 1200)
    text = (base/'unit.log').read_text()
    if re.search(r'(?m)^(FAIL|ERROR|%Error)\b', text):
        raise ValueError('unit failure in '+variant)
    count = len(re.findall(r'(?m)^PASS', text))
    if count < 186:
        raise ValueError('incomplete unit suite')
    (base/'unit.json').write_text(json.dumps({'passed': True, 'pass_lines': count}, indent=2)+'\n')
    print('UNIT', variant, count, flush=True)


def matrix(variant):
    base = OUT/variant
    execute([sys.executable, '-B', ROOT/'tools/run_parameter_matrix.py', '--filelist', base/'filelist.f',
             '--build-root', base/'matrix', '--report', base/'matrix.json', '--jobs', '2', '--lint-jobs', '2'],
            base/'matrix-driver.log', 5400)
    r = json.loads((base/'matrix.json').read_text())
    if not r['passed'] or not r['completed'] or not r['sources_unchanged']:
        raise ValueError('matrix failed')
    print('MATRIX', variant, len(r['checks']), flush=True)


def synthesis(job):
    variant, config = job
    name = '{}x{}-p{}-r{}'.format(*config)
    dest = OUT/variant/'synth'
    dest.mkdir(exist_ok=True)
    report = dest/(name+'.json')
    if report.exists() and json.loads(report.read_text()).get('passed'):
        return
    fe, be, phys, rob = config
    execute([sys.executable, '-B', ROOT/'tools/run_synthesis.py', '--filelist', OUT/variant/'filelist.f',
             '--out', dest, '--report', report, '--mode', 'opt', '--jobs', '1', '--timeout', '2400',
             '--fe-width', fe, '--be-width', be, '--phys-regs', phys, '--rob-entries', rob],
            dest/(name+'.driver.log'), 2500)
    r = json.loads(report.read_text())
    if not r['passed'] or not r['sources_unchanged']:
        raise ValueError('synthesis failed')
    print('SYNTH', variant, name, r['results'][0]['report']['timing']['estimated_fmax_mhz'], flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--phase', choices=('unit', 'matrix', 'simulation', 'synthesis'), required=True)
    p.add_argument('--variants', nargs='+', choices=VARIANTS, default=list(VARIANTS))
    p.add_argument('--config')
    args = p.parse_args()
    stage()
    configs = [tuple(map(int, args.config.split(',')))] if args.config else list(CONFIGS)[::-1]
    if args.phase == 'simulation':
        for c in configs:
            for v in args.variants:
                bench.run_config(v, c, None)
    elif args.phase == 'synthesis':
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(synthesis, [(v, c) for c in configs for v in args.variants]))
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(unit if args.phase == 'unit' else matrix, args.variants))
    stage()
