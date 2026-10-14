#!/usr/bin/env python3
"""Check disjoint byte ranges through legal LSQ transactions and reject the old path."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/load-nonoverlap-20261014/targeted-qualified'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=False)
    tb = ROOT/'tb/rv32_load_store_queue_tb.v'
    sources = [ROOT/'rtl/rv32_load_store_queue.v', ROOT/'rtl/rv32im_defs.vh', tb,
               ROOT/'build/load-nonoverlap-20261014/baseline/source/rtl/rv32_load_store_queue.v',
               Path(__file__)]
    hashes = {str(p): digest(p) for p in sources}
    tests = []
    for variant in ('baseline', 'candidate'):
        widths = (1, 2, 4)
        robs = (32,) if variant == 'baseline' else (16, 32, 64)
        modes = (0,) if variant == 'baseline' else (0, 1)
        for width in widths:
            for rob in robs:
                for mode in modes:
                    name = f'{variant}-w{width}-r{rob}-posted{mode}'
                    rtl = sources[3] if variant == 'baseline' else sources[0]
                    binary = OUT/(name+'.vvp')
                    command = ['timeout', '-k', '5', '30', 'iverilog', '-g2005', '-I', str(ROOT/'rtl'),
                        '-s', 'rv32_load_store_queue_tb', '-P', f'rv32_load_store_queue_tb.BE_WIDTH={width}',
                        '-P', f'rv32_load_store_queue_tb.ROB_ENTRIES={rob}',
                        '-P', f'rv32_load_store_queue_tb.ROB_INDEX_WIDTH={rob.bit_length()-1}',
                        '-P', f'rv32_load_store_queue_tb.LSQ_ENTRIES={16 if width == 4 else 8}',
                        '-P', f'rv32_load_store_queue_tb.LSQ_INDEX_WIDTH={4 if width == 4 else 3}',
                        '-P', f'rv32_load_store_queue_tb.POSTED_STORES={mode}',
                        '-P', f'rv32_load_store_queue_tb.LOAD_FALLTHROUGH={mode}', '-o', str(binary), str(rtl), str(tb)]
                    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
                    build_log = OUT/(name+'-build.log')
                    build_log.write_text(result.stdout+result.stderr)
                    assert result.returncode == 0, build_log
                    run = ['timeout', '-k', '5', '30', 'vvp', '-N', str(binary)]
                    result = subprocess.run(run, cwd=ROOT, capture_output=True, text=True)
                    log = OUT/(name+'.log')
                    log.write_text(result.stdout+result.stderr)
                    rejected = variant == 'baseline'
                    if rejected:
                        assert result.returncode == 1 and 'disjoint store skips bubble' in log.read_text(), log
                        checks = None
                    else:
                        match = re.search(r'PASS rv32_load_store_queue_tb width=\d+ checks=(\d+)', log.read_text())
                        assert result.returncode == 0 and match, log
                        assert not re.search(r'(?m)^(ERROR|FAIL)\b', log.read_text()), log
                        checks = int(match[1])
                    tests.append({'name': name, 'passed': True, 'expected_rejection': rejected,
                        'checks': checks, 'commands': [command, run],
                        'build_log': str(build_log), 'build_log_sha256': digest(build_log),
                        'log': str(log), 'log_sha256': digest(log)})
                    print('PASS', name, 'expected rejection' if rejected else checks, flush=True)
    assert all(digest(Path(p)) == sha for p, sha in hashes.items())
    (OUT/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'sources_unchanged': True, 'source_sha256': hashes, 'tests': tests}, indent=2)+'\n')


if __name__ == '__main__':
    main()
