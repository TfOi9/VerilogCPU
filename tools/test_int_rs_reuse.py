#!/usr/bin/env python3
"""Check same-cycle wakeup, inactive payload and slot reuse with timeouts."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/int-rs-reuse-unit'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    files = [ROOT/'rtl/rv32_ranked_select.v', ROOT/'rtl/rv32_integer_reservation_station.v',
             ROOT/'rtl/rv32im_defs.vh', ROOT/'tb/rv32_int_rs_reuse_tb.v', Path(__file__)]
    hashes = {str(p): digest(p) for p in files}
    tests = []
    for width in (1, 2, 4):
        for rob in (16, 32, 64):
            name = f'w{width}-r{rob}'
            binary = OUT/name
            top = 'rv32_int_rs_reuse_tb'
            build = ['iverilog', '-g2005', '-I', str(ROOT/'rtl'), '-s', top,
                '-P', f'{top}.BE_WIDTH={width}', '-P', f'{top}.ROB_ENTRIES={rob}',
                '-P', f'{top}.ROB_INDEX_WIDTH={rob.bit_length()-1}', '-o', str(binary),
                *map(str, [files[0], files[1], files[3]])]
            for phase, command in (('build', build), ('run', ['vvp', '-N', str(binary)])):
                command = ['timeout', '-k', '5', '30', *command]
                result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
                log = OUT/(name+'-'+phase+'.log')
                log.write_text(result.stdout+result.stderr)
                (OUT/(name+'-'+phase+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
                assert result.returncode == 0 and not re.search(r'(?m)^(FAIL|ERROR)\b', log.read_text()), log
                if phase == 'run':
                    match = re.search(r'PASS RS reuse .* checks=(\d+)', log.read_text())
                    assert match and int(match[1]) == 4096, log
                    tests.append({'name': name, 'checks': int(match[1]), 'passed': True,
                        'log': str(log), 'log_sha256': digest(log)})
                    print(log.read_text().splitlines()[0], flush=True)
    assert all(digest(Path(p)) == sha for p, sha in hashes.items())
    (OUT/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'sources_unchanged': True, 'source_sha256': hashes, 'tests': tests}, indent=2)+'\n')


if __name__ == '__main__':
    main()
