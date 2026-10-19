#!/usr/bin/env python3
"""Check compact Load-value tags at RAM bounds and high-address aliases."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build'/('load-value-bounds-'+str(time.time_ns()))
OUT.mkdir(parents=True)
source = ROOT/'rtl/rv32_load_store_queue.v'
fixture = ROOT/'tb/rv32_load_store_queue_tb.v'
text = fixture.read_text().split('    initial begin\n')[0]
text = text.replace('module rv32_load_store_queue_tb;', '''module rv32_load_store_queue_tb;
    parameter TEST_MEMORY_BYTES = 268435456;
    parameter TEST_VALUE_ENTRIES = 64;''')
text = text.replace('.POSTED_STORES(POSTED_STORES),', '''.MEMORY_BYTES(TEST_MEMORY_BYTES), .LOAD_VALUE_ENTRIES(TEST_VALUE_ENTRIES),
        .POSTED_STORES(POSTED_STORES),''')
text += '''    initial begin
        clk_i = 0; checks = 0;
        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        load_address(tag(0), first_tag, 0);
        expect_request(0, 0, 0);
        send_response(32'h12345678, 0);
        expect_completion(tag(0), 32'h12345678, 0, 0);
        allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        load_address(tag(1), second_tag, 32'h80000000);
        expect_completion(tag(1), 0, 1, 5);
        check(!cache_request_valid_o, "high alias cannot bypass access fault");
        allocate_one(0, tag(2), `RV32_MEMORY_WORD, 0, third_tag);
        load_address(tag(2), third_tag, TEST_MEMORY_BYTES);
        expect_completion(tag(2), 0, 1, 5);
        check(!cache_request_valid_o, "upper bound cannot bypass access fault");
        allocate_one(0, tag(3), `RV32_MEMORY_WORD, 0, second_tag);
        load_address(tag(3), second_tag, 0);
        expect_completion(tag(3), 32'h12345678, 0, 0);
        check(!cache_request_valid_o, "valid cached word survives invalid aliases");
        if (TEST_MEMORY_BYTES >= 1024) begin
            reset_case();
            allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
            load_address(tag(0), first_tag, TEST_MEMORY_BYTES/2);
            expect_request(0, TEST_MEMORY_BYTES/2, 0);
            send_response(32'h87654321, 0);
            expect_completion(tag(0), 32'h87654321, 0, 0);
            allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
            load_address(tag(1), second_tag, 0);
            expect_request(0, 0, 0);
            send_response(32'hdeadbeef, 0);
            expect_completion(tag(1), 32'hdeadbeef, 0, 0);
        end
        reset_case();
        allocate_one(0, tag(0), `RV32_MEMORY_WORD, 0, first_tag);
        load_address(tag(0), first_tag, TEST_MEMORY_BYTES-4);
        expect_request(0, TEST_MEMORY_BYTES-4, 0);
        send_response(32'hfedcba98, 0);
        expect_completion(tag(0), 32'hfedcba98, 0, 0);
        allocate_one(0, tag(1), `RV32_MEMORY_WORD, 0, second_tag);
        load_address(tag(1), second_tag, TEST_MEMORY_BYTES-4);
        expect_completion(tag(1), 32'hfedcba98, 0, 0);
        check(!cache_request_valid_o, "last RAM word remains cacheable");
        $display("PASS Load bounds RAM=%0d entries=%0d checks=%0d",
            TEST_MEMORY_BYTES, TEST_VALUE_ENTRIES, checks);
        $finish;
    end
endmodule
'''
bench = OUT/'bounds.v'
bench.write_text(text)
result = {'completed': False, 'passed': False,
          'source_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in (source, fixture, bench, Path(__file__))}, 'cases': []}
try:
    for memory in (4, 1024, 1048576, 268435456):
        for entries in (1, 4, 64):
            label = f'{memory}-{entries}'
            sim = OUT/(label+'.vvp')
            command = ['timeout', '-k', '2', '30', 'iverilog', '-g2005', '-I', str(ROOT/'rtl'),
                       '-s', 'rv32_load_store_queue_tb', '-o', str(sim),
                       '-Prv32_load_store_queue_tb.TEST_MEMORY_BYTES='+str(memory),
                       '-Prv32_load_store_queue_tb.TEST_VALUE_ENTRIES='+str(entries), str(source), str(bench)]
            p = subprocess.run(command, capture_output=True, text=True)
            (OUT/(label+'.build.log')).write_text(p.stdout+p.stderr)
            assert p.returncode == 0, label
            p = subprocess.run(['timeout', '-k', '2', '10', 'vvp', '-n', str(sim)], capture_output=True, text=True)
            (OUT/(label+'.log')).write_text(p.stdout+p.stderr)
            assert p.returncode == 0 and 'PASS Load bounds' in p.stdout and 'FAIL' not in p.stdout, (label, p.stdout)
            result['cases'].append({'memory_bytes': memory, 'value_entries': entries, 'passed': True})
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p,h in result['source_sha256'].items())
    result.update(completed=True, passed=True)
finally:
    (OUT/'results.json').write_text(json.dumps(result, indent=2)+'\n')
print('PASS Load bounds', len(result['cases']), OUT)
