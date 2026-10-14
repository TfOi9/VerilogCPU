#!/usr/bin/env python3
"""Prove the new contract guards reject deliberate faults in frozen test copies."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/deep-20261014/negative-controls'


def main():
    OUT.mkdir(parents=True, exist_ok=False)
    cache = ['rtl/rv32_load_store_queue.v','rtl/rv32_l1_data_cache.v',
             'tb/rv32_main_memory.v','../RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv']
    wb = ['rtl/rv32_completion_writeback_network.v','rtl/rv32_ranked_select.v',
          'rtl/rv32_reorder_buffer.v','rtl/rv32_physical_register_file.v']
    scenarios = [
        ('posted-error','rv32_posted_store_tb',cache,True,
         '        recover_i = 1; rollback_valid = 1;',
         "        force cache_response_error = 1'b1;\n        recover_i = 1; rollback_valid = 1;",
         'ERROR rv32_load_store_queue posted store returned an error'),
        ('lost-line','rv32_posted_store_tb',cache,True,
         '        commit_fire_i = 1; tick();',
         "        commit_fire_i = 1; tick();\n        force cache.s2_hit = 1'b0;",
         'ERROR rv32_l1_data_cache irrevocable store lost its line'),
        ('authorization','rv32_result_bypass_rob_tb',wb,False,
         "        source_value_i[31:0] = 32'hdeadbeef; #1;",
         "        source_value_i[31:0] = 32'hdeadbeef;\n        force lookup_valid = {SOURCE_COUNT{1'b1}}; #1;",
         'ERROR rv32_completion_writeback_network source authorization mismatch'),
    ]
    rows = []
    for name,top,sources,sv,old,new,error in scenarios:
        text = (ROOT/'tb'/(top+'.v')).read_text()
        assert old in text
        copied = OUT/(name+'.v');copied.write_text(text.replace(old,new,1))
        binary = OUT/name
        command = ['timeout','-k','5','30','iverilog','-g2012' if sv else '-g2005',
                   '-I','rtl','-s',top,'-o',str(binary),*sources,str(copied)]
        build = subprocess.run(command,cwd=ROOT,text=True,capture_output=True)
        (OUT/(name+'-build.log')).write_text(build.stdout+build.stderr)
        assert build.returncode == 0
        run = subprocess.run(['timeout','-k','5','30','vvp','-N',str(binary)],
                             cwd=ROOT,text=True,capture_output=True)
        log = run.stdout+run.stderr;(OUT/(name+'.log')).write_text(log)
        assert run.returncode != 0 and error in log, name
        rows.append({'name':name,'passed':True,'returncode':run.returncode,
                     'expected_guard':error,'log_sha256':hashlib.sha256(log.encode()).hexdigest()})
        print('PASS negative control',name,'status',run.returncode,flush=True)
    (OUT/'results.json').write_text(json.dumps({'passed':True,'tests':rows},indent=2)+'\n')


if __name__ == '__main__':
    main()
