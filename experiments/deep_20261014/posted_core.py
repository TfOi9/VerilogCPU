#!/usr/bin/env python3
"""Retirement differential tests with an error-free posted-write memory model."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/deep-20261014/posted-core'


def main():
    OUT.mkdir(parents=True,exist_ok=False)
    sources = [ROOT/'rtl'/Path(x).name for x in (ROOT/'verilog/filelist.f').read_text().splitlines() if x.strip()]
    sources = [p for p in sources if not p.name.startswith('rv32_l1_') and p.name!='student_top.v']
    tb = ROOT/'tb/rv32_cpu_core_posted_tb.v'
    files = sources+[tb,Path(__file__),ROOT/'tools/generate_core_vectors.py']
    hashes = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    rows = []
    def run(command,name,limit):
        command=['timeout','-k','5',str(limit),*map(str,command)]
        result=subprocess.run(command,cwd=ROOT,text=True,capture_output=True)
        log=result.stdout+result.stderr;(OUT/(name+'.log')).write_text(log)
        (OUT/(name+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
        assert result.returncode==0 and '\nFAIL ' not in log and '\nERROR ' not in log,name
        return log
    seeds=(9217,9218,9219)
    for seed in seeds:
        run([sys.executable,'-B',ROOT/'tools/generate_core_vectors.py',
             '--seed',seed,'--out',OUT/str(seed)],'generate-'+str(seed),30)
    for fe,be,phys,rob in ((1,1,48,16),(2,2,64,32),(4,4,96,64)):
        name='{}x{}-p{}-r{}'.format(fe,be,phys,rob);obj=OUT/name
        run(['verilator','--binary','--timing','--trace','--assert','--language','1364-2005',
             '-Wall','-Wno-fatal','-DRV32_TEST_WATCHDOG','-I'+str(ROOT/'rtl'),
             '--top-module','rv32_cpu_core_posted_tb','--Mdir',obj,'-o','sim','-j','2',
             '-GFE_WIDTH='+str(fe),'-GBE_WIDTH='+str(be),'-GPHYS_REGS='+str(phys),
             '-GROB_ENTRIES='+str(rob),*sources,tb],name+'-build',180)
        for seed in seeds:
            log=run([obj/'sim','+PROGRAM='+str(OUT/(str(seed)+'.words')),
                     '+TRACE='+str(OUT/(str(seed)+'.trace')),
                     '+EXPECTED='+(OUT/(str(seed)+'.result')).read_text().strip(),
                     '+SEED='+str(seed)],name+'-'+str(seed),30)
            assert 'PASS core ' in log
            rows.append({'configuration':[fe,be,phys,rob],'seed':seed,'passed':True,
                         'log_sha256':hashlib.sha256(log.encode()).hexdigest()})
            print('PASS posted retirement',name,seed,flush=True)
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in hashes.items())
    record={'passed':True,'source_sha256':hashes,'tests':rows,
            'scope':'posted ordinary writes; ordered one-inflight error-free test memory, no L1 cache'}
    (OUT/'results.json').write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':
    main()
