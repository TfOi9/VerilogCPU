#!/usr/bin/env python3
"""Run fresh identical official mapping for the combined RTL candidate."""
import concurrent.futures
import json
import sys
from combined import stage,CONFIGS
from repair import ROOT,OUT
from run import execute

def run(config):
    fe,be,phys,rob=config
    name=f'{fe}x{be}-p{phys}-r{rob}'
    target=OUT/'combined/synth'
    target.mkdir(exist_ok=True)
    report=target/(name+'.json')
    if report.exists() and json.loads(report.read_text()).get('passed'):
        return True
    execute([sys.executable,'-B',ROOT/'tools/run_synthesis.py','--filelist',OUT/'combined/filelist.f',
        '--out',target,'--report',report,'--mode','opt','--jobs','1','--timeout','2400',
        '--fe-width',str(fe),'--be-width',str(be),'--phys-regs',str(phys),'--rob-entries',str(rob)],target/(name+'.driver.log'),2500)
    passed=json.loads(report.read_text())['passed']
    print(name,passed,flush=True)
    return passed

if __name__=='__main__':
    stage()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(run,CONFIGS))
    stage()
    raise SystemExit(0 if all(results) else 1)
