#!/usr/bin/env python3
"""Qualify memory parallelism, errors, backpressure and tagged retirement."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    files=list((ROOT/'rtl').glob('*'))+list((ROOT/'tb').glob('*.v'))+[Path(__file__),ROOT/'tools/generate_core_vectors.py']
    hashes={str(p):digest(p) for p in files if p.is_file()};tests=[]
    def run(cmd,name,limit=30):
        cmd=['timeout','-k','5',str(limit),*map(str,cmd)]
        r=subprocess.run(cmd,cwd=ROOT,text=True,capture_output=True);log=out/(name+'.log');log.write_text(r.stdout+r.stderr)
        (out/(name+'.command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
        if r.returncode or re.search(r'(?m)^(ERROR|FAIL|%Error)\b',log.read_text()):raise RuntimeError(name)
        return log
    ram=ROOT.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'
    for ways in (1,2):
        for seed in (1,2,7,42):
            name=f'cache-{ways}-{seed}';exe=out/name
            run(['iverilog','-g2012','-s','rv32_cache_hum_tb','-P',f'rv32_cache_hum_tb.WAYS={ways}','-P',f'rv32_cache_hum_tb.SEED={seed}','-o',exe,ram,ROOT/'rtl/rv32_l1_data_cache.v',ROOT/'tb/rv32_cache_hum_tb.v'],name+'-build')
            log=run(['vvp','-N',exe],name);assert 'PASS Cache HUM' in log.read_text()
            tests.append({'name':name,'passed':True,'log_sha256':digest(log)});print('PASS',name,flush=True)
    for seed in (1,2,7,42,101,1729,65537,1234567):
        name=f'bridge-{seed}';exe=out/name
        run(['iverilog','-g2005','-s','rv32_l1_cache_parallel_tb','-P',f'rv32_l1_cache_parallel_tb.SEED={seed}','-o',exe,ROOT/'rtl/rv32_l1_cache_axi_bridge.v',ROOT/'tb/rv32_l1_cache_parallel_tb.v'],name+'-build')
        log=run(['vvp','-N',exe],name);assert 'PASS parallel bridge' in log.read_text()
        tests.append({'name':name,'passed':True,'log_sha256':digest(log)});print('PASS',name,flush=True)
    name='tagged-lsq';exe=out/name
    run(['iverilog','-g2005','-Irtl','-s','rv32_lsq_tagged_tb','-o',exe,ROOT/'rtl/rv32_load_store_queue.v',ROOT/'tb/rv32_lsq_tagged_tb.v'],name+'-build')
    log=run(['vvp','-N',exe],name);assert 'PASS tagged LSQ' in log.read_text()
    tests.append({'name':name,'passed':True,'log_sha256':digest(log)});print('PASS',name,flush=True)
    name='tagged-lsq-reject-wrong-tag';exe=out/name
    run(['iverilog','-g2005','-Irtl','-s','rv32_lsq_tagged_tb','-P','rv32_lsq_tagged_tb.BAD_TAG=1','-o',exe,ROOT/'rtl/rv32_load_store_queue.v',ROOT/'tb/rv32_lsq_tagged_tb.v'],name+'-build')
    cmd=['timeout','-k','5','30','vvp','-N',str(exe)]
    result=subprocess.run(cmd,cwd=ROOT,text=True,capture_output=True)
    log=out/(name+'.log');log.write_text(result.stdout+result.stderr)
    (out/(name+'.command.json')).write_text(json.dumps(cmd,indent=2)+'\n')
    guards=('ERROR rv32_load_store_queue live response lost its LSQ entry',
            'ERROR rv32_load_store_queue response ROB tag mismatch')
    matched=[guard for guard in guards if guard in log.read_text()]
    assert result.returncode == 1 and matched
    tests.append({'name':name,'passed':True,'expected_rejection':True,'expected_guard':matched[0],'log_sha256':digest(log)});print('PASS',name,flush=True)
    name='posted-wrap';exe=out/name
    run(['iverilog','-g2005','-Irtl','-s','rv32_lsq_posted_wrap_tb','-o',exe,ROOT/'rtl/rv32_load_store_queue.v',ROOT/'tb/rv32_lsq_posted_wrap_tb.v'],name+'-build')
    log=run(['vvp','-N',exe],name);assert 'PASS posted LSQ' in log.read_text()
    tests.append({'name':name,'passed':True,'log_sha256':digest(log)});print('PASS',name,flush=True)
    seeds=(9317,9318,9319)
    for seed in seeds:
        run([sys.executable,'-B',ROOT/'tools/generate_core_vectors.py','--seed',seed,'--out',out/str(seed)],f'generate-{seed}')
    sources=[ROOT/'rtl'/Path(x).name for x in (ROOT/'verilog/filelist.f').read_text().splitlines() if x.strip()]
    sources=[p for p in sources if not p.name.startswith('rv32_l1_') and p.name!='student_top.v']
    for fe,be,phys,rob in ((1,1,48,16),(2,2,64,32),(4,4,96,64)):
        name=f'core-{fe}x{be}-p{phys}-r{rob}';obj=out/name
        run(['verilator','--binary','--timing','--assert','--language','1364-2005','-Wall','-Wno-fatal','-DRV32_TEST_WATCHDOG','-I'+str(ROOT/'rtl'),'--top-module','rv32_cpu_core_tagged_tb','--Mdir',obj,'-o','sim','-j','2','-GFE_WIDTH='+str(fe),'-GBE_WIDTH='+str(be),'-GPHYS_REGS='+str(phys),'-GROB_ENTRIES='+str(rob),*sources,ROOT/'tb/rv32_cpu_core_tagged_tb.v'],name+'-build',240)
        for seed in seeds:
            log=run([obj/'sim','+PROGRAM='+str(out/(str(seed)+'.words')),'+TRACE='+str(out/(str(seed)+'.trace')),'+EXPECTED='+(out/(str(seed)+'.result')).read_text().strip(),'+SEED='+str(seed)],name+'-'+str(seed));assert 'PASS core ' in log.read_text()
            tests.append({'name':name+'-'+str(seed),'passed':True,'log_sha256':digest(log)});print('PASS',name,seed,flush=True)
    unchanged=all(digest(Path(p))==h for p,h in hashes.items());assert unchanged
    (out/'results.json').write_text(json.dumps({'completed':True,'passed':True,'sources_unchanged':unchanged,'source_sha256':hashes,'tests':tests},indent=2)+'\n')
if __name__=='__main__':main()
