#!/usr/bin/env python3
"""Run identical fresh official synthesis for all isolated variants."""
import concurrent.futures
import json
import subprocess
import sys
from setup import ROOT, OUT, CONFIGS, VARIANTS, verify

def run(job):
    variant, (fe, be, phys, rob) = job
    name = f'{fe}x{be}-p{phys}-r{rob}'
    target = OUT/variant/'synth'
    target.mkdir(parents=True, exist_ok=True)
    report = target/(name+'.json')
    if report.exists():
        old = json.loads(report.read_text())
        if old.get('completed') and old.get('passed'):
            print('REUSE current round', variant, name, flush=True)
            return True
    command = [sys.executable, '-B', str(ROOT/'tools/run_synthesis.py'),
               '--filelist', str(OUT/variant/'filelist.f'), '--out', str(target),
               '--report', str(report), '--mode', 'opt', '--jobs', '1', '--timeout', '2400',
               '--fe-width', str(fe), '--be-width', str(be), '--phys-regs', str(phys), '--rob-entries', str(rob)]
    print('START', variant, name, flush=True)
    with (target/(name+'.driver.log')).open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=2500, cwd=ROOT)
    passed = result.returncode == 0 and json.loads(report.read_text())['passed']
    print('DONE', variant, name, passed, flush=True)
    return passed

if __name__ == '__main__':
    verify()
    jobs = [(v, c) for c in CONFIGS for v in VARIANTS]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(run, jobs))
    verify()
    raise SystemExit(0 if all(results) else 1)
