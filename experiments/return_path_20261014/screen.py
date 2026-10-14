#!/usr/bin/env python3
"""Run existing memory and completion protocol tests on frozen candidates."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/return-path-20261014/screen-v2'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=False)
    tests = []
    inputs = {}
    for variant in ('metadata-v2', 'metadata-wb-v2'):
        rtl = ROOT/'build/return-path-20261014'/variant/'source/rtl'

        def test(top, files, options, name):
            paths = [rtl/n for n in files]+[ROOT/'tb'/(top+'.v'), ROOT/'rtl/rv32im_defs.vh']
            inputs.update({str(p): digest(p) for p in paths})
            label = variant+'-'+name
            binary = OUT/label
            build = ['timeout', '-k', '5', '30', 'iverilog', '-g2005', '-I', str(rtl),
                '-s', top, *options, '-o', str(binary), *map(str, paths[:-1])]
            for command, suffix in ((build, '-build'), (['timeout', '-k', '5', '30', 'vvp', '-N', str(binary)], '')):
                result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
                log = OUT/(label+suffix+'.log')
                log.write_text(result.stdout+result.stderr)
                assert result.returncode == 0 and not re.search(r'(?m)^(FAIL|ERROR)\b', log.read_text()), log
                if not suffix:
                    assert 'PASS' in log.read_text(), log
                    tests.append({'variant': variant, 'name': name, 'passed': True,
                        'log': str(log), 'log_sha256': digest(log)})
            print('PASS', label, flush=True)

        for width in (1, 2, 4):
            for mode in (0, 1):
                test('rv32_load_store_queue_tb', ['rv32_load_store_queue.v'],
                    ['-P', f'rv32_load_store_queue_tb.BE_WIDTH={width}',
                     '-P', f'rv32_load_store_queue_tb.POSTED_STORES={mode}',
                     '-P', f'rv32_load_store_queue_tb.LOAD_FALLTHROUGH={mode}'], f'lsq-{width}-{mode}')
            test('rv32_result_bypass_tb', ['rv32_ranked_select.v', 'rv32_completion_writeback_network.v'],
                ['-P', f'rv32_result_bypass_tb.BE_WIDTH={width}',
                 '-P', f'rv32_result_bypass_tb.SOURCE_COUNT={width+3}'], f'wb-{width}')
        for width in (2, 4):
            test('rv32_result_bypass_rob_tb', ['rv32_ranked_select.v', 'rv32_completion_writeback_network.v',
                'rv32_reorder_buffer.v', 'rv32_physical_register_file.v'],
                ['-P', f'rv32_result_bypass_rob_tb.BE_WIDTH={width}'], f'wb-rob-{width}')
    assert all(digest(Path(p)) == sha for p, sha in inputs.items())
    (OUT/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'sources_unchanged': True, 'source_sha256': inputs, 'tests': tests}, indent=2)+'\n')


if __name__ == '__main__':
    main()
