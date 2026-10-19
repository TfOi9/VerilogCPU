#!/usr/bin/env python3
"""Prove that required fetch tag bits and unknown values cannot pass the fixture."""
import hashlib
import itertools
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
out = root/'build'/('fetch-tag-negative-'+str(time.time_ns()))
out.mkdir(parents=True, exist_ok=False)
source = root/'rtl/rv32_fetch_pipeline.v'
original = source.read_text()
mutations = {
    'drop-low-tag': original.replace('4 + LINE_BUFFER_INDEX_WIDTH : 4;', '5 + LINE_BUFFER_INDEX_WIDTH : 5;'),
    'drop-high-tag': original.replace('32 - LINE_BUFFER_TAG_LOW;', '31 - LINE_BUFFER_TAG_LOW;').replace('[31:LINE_BUFFER_TAG_LOW]', '[30:LINE_BUFFER_TAG_LOW]'),
    'unknown-tag': original.replace('<= response_pc[31:LINE_BUFFER_TAG_LOW];', '<= {LINE_BUFFER_TAG_WIDTH{1\'bx}};')
}
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
inputs = [source, root/'tb/rv32_fetch_sram_buffer_tb.v', Path(__file__)]
result = dict(completed=False, passed=False, source_sha256={str(p):digest(p) for p in inputs}, tests=[])
try:
    for mutation, text in mutations.items():
        assert text != original
        mutant = out/(mutation+'.v'); mutant.write_text(text)
        for entries, fe, sram in itertools.product((1,4,64), (1,2,4), (0,1)):
            label = f'{mutation}-e{entries}-f{fe}-s{sram}'
            top = 'rv32_fetch_sram_buffer_tb';binary = out/label
            options = [v for k,n in dict(FE_WIDTH=fe, BE_WIDTH=4, LINE_BUFFER_ENTRIES=entries, USE_SRAM=sram).items() for v in ('-P',f'{top}.{k}={n}')]
            sources = [root.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv',root/'rtl/rv32im_decoder.v',root/'rtl/rv32_branch_predictor.v',mutant,root/'tb'/f'{top}.v']
            command = ['timeout','-k','5','45','iverilog','-g2012','-I',str(root/'rtl'),'-s',top,*options,'-o',str(binary),*map(str,sources)]
            p = subprocess.run(command,cwd=root,capture_output=True,text=True)
            (out/(label+'-build.log')).write_text(p.stdout+p.stderr)
            assert p.returncode == 0, label
            command = ['timeout','-k','5','45','vvp','-N',str(binary)]
            p = subprocess.run(command,cwd=root,capture_output=True,text=True)
            log = out/(label+'-run.log');log.write_text(p.stdout+p.stderr)
            assert p.returncode in (0,1) and 'ERROR fetch_line_buffer ' in log.read_text(), label
            result['tests'].append(dict(name=label, passed=True, log_sha256=digest(log)))
    assert all(digest(Path(p))==h for p,h in result['source_sha256'].items())
    result.update(completed=True,passed=True)
finally:
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS fetch tag negative controls',len(result['tests']))
