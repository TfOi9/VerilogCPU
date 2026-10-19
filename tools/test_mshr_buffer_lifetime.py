#!/usr/bin/env python3
"""Reject a refill request that can overwrite an unaccepted writeback payload."""
import hashlib
import itertools
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build'/('mshr-buffer-lifetime-'+str(time.time_ns()))
OUT.mkdir(parents=True)
source = ROOT/'rtl/rv32_l1_data_cache.v'
original = source.read_text()
needle = '(!m_wb_valid[m_scan] || m_wb_sent[m_scan])'
assert original.count(needle) == 1
mutant = OUT/'early-refill.v'
mutant.write_text(original.replace(needle, "1'b1"))
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
inputs = [source, ROOT/'tb/rv32_cache_multi_mshr_tb.v', Path(__file__)]
result = dict(completed=False, passed=False, source_sha256={str(p):digest(p) for p in inputs}, tests=[])
try:
    for mshrs, ways, waiters in itertools.product((2,4), (1,2,4), (2,4)):
        label = f'm{mshrs}-w{ways}-q{waiters}'
        top = 'rv32_cache_multi_mshr_tb'
        options = [v for k,n in dict(MSHRS=mshrs, SETS=8, WAYS=ways, WAITERS=waiters, LATENCY=31, SEED=42).items() for v in ('-P',f'{top}.{k}={n}')]
        for negative, rtl in ((False,source),(True,mutant)):
            name = label+('-bad' if negative else '-good');binary = OUT/name
            commands = [['iverilog','-g2012','-I',str(ROOT/'rtl'),'-s',top,*options,'-o',str(binary),str(ROOT.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'),str(rtl),str(ROOT/'tb'/f'{top}.v')], ['vvp','-N',str(binary)]]
            for phase, command in zip(('build','run'),commands):
                command = ['timeout','-k','5','45',*command]
                p = subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
                log = OUT/(name+'-'+phase+'.log');log.write_text(p.stdout+p.stderr)
                (OUT/(name+'-'+phase+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
                if phase == 'build': assert p.returncode == 0, log
                elif negative: assert p.returncode != 0 and 'read issued before writeback payload acceptance' in log.read_text(), log
                else: assert p.returncode == 0 and 'PASS ' in log.read_text() and 'FAIL' not in log.read_text(), log
            result['tests'].append(dict(name=name, negative=negative, passed=True, log_sha256=digest(log)))
    assert all(digest(Path(p))==h for p,h in result['source_sha256'].items())
    result.update(completed=True,passed=True)
finally:
    (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS MSHR buffer lifetime',len(result['tests']))
