#!/usr/bin/env python3
"""Reject an overfull same-line waiter queue across cache configurations."""
import hashlib
import itertools
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
out = root/'build'/('waiter-overflow-'+str(time.time_ns()))
out.mkdir(parents=True, exist_ok=False)
cache = root/'rtl/rv32_l1_data_cache.v'
text = cache.read_text()
needle = 'm_count[m_match_slot] < MSHR_WAITERS[WAITER_INDEX_WIDTH:0]'
assert text.count(needle) == 1
mutant = out/'overflow.v'
mutant.write_text(text.replace(needle, 'm_count[m_match_slot] <= MSHR_WAITERS[WAITER_INDEX_WIDTH:0]'))
inputs = [cache, root/'tb/rv32_cache_multi_mshr_tb.v', Path(__file__)]
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
result = dict(completed=False, passed=False, source_sha256={str(p):digest(p) for p in inputs}, tests=[])
try:
    for mshrs, ways, seed in itertools.product((2,4), (1,2,4), (1,42)):
        label = f'm{mshrs}-w{ways}-s{seed}'
        binary = out/label
        top = 'rv32_cache_multi_mshr_tb'
        options = [v for k,n in dict(WAITERS=2, MSHRS=mshrs, SETS=8, WAYS=ways, LATENCY=31, SEED=seed).items() for v in ('-P',f'{top}.{k}={n}')]
        commands = [['iverilog','-g2012','-I',str(root/'rtl'),'-s',top,*options,'-o',str(binary),str(root.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'),str(mutant),str(root/'tb'/f'{top}.v')], ['vvp','-N',str(binary)]]
        for phase, cmd in zip(('build','run'), commands):
            command = ['timeout','-k','5','45',*cmd]
            p = subprocess.run(command,cwd=root,capture_output=True,text=True)
            log = out/(label+'-'+phase+'.log');log.write_text(p.stdout+p.stderr)
            (out/(label+'-'+phase+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
            if phase == 'build': assert p.returncode == 0, log
            else: assert p.returncode != 0 and 'ERROR rv32_l1_data_cache invalid MSHR waiter count' in log.read_text(), log
        result['tests'].append(dict(name=label, passed=True, log_sha256=digest(log)))
    assert all(digest(Path(p))==h for p,h in result['source_sha256'].items())
    result.update(completed=True,passed=True)
finally:
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS twelve waiter overflow negative controls')
