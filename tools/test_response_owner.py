#!/usr/bin/env python3
"""Check top-level response ownership independently of the protocol engines."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'build/response-owner-unit')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ram = ROOT.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'
    sources = [ram, *sorted((ROOT/'rtl').glob('*.v')), ROOT/'tb/rv32_response_owner_tb.v']
    hashes = {str(p): digest(p) for p in sources + list((ROOT/'rtl').glob('*.vh')) + [Path(__file__)]}
    rows = []
    for rob, tag_width in ((16, 6), (32, 7), (64, 8)):
        binary = out/str(rob)
        commands = [
            ['iverilog', '-g2012', '-D', 'SYNTHESIS', '-I', str(ROOT/'rtl'),
             '-s', 'rv32_response_owner_tb', '-P', 'rv32_response_owner_tb.ROB_ENTRIES='+str(rob),
             '-P', 'rv32_response_owner_tb.ROB_TAG_WIDTH='+str(tag_width),
             '-o', str(binary), *map(str, sources)],
            ['vvp', '-N', str(binary)]]
        for phase, command in zip(('build', 'run'), commands):
            command = ['timeout', '-k', '5', '30', *command]
            result = subprocess.run(command, capture_output=True, text=True)
            log = out/(str(rob)+'-'+phase+'.log')
            log.write_text(result.stdout+result.stderr)
            (out/(str(rob)+'-'+phase+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
            assert result.returncode == 0 and 'FAIL ' not in log.read_text(), log
            if phase == 'run':
                assert 'PASS response owner' in result.stdout
                rows.append({'rob': rob, 'checks': (1 << (tag_width+1))*8,
                             'log_sha256': digest(log)})
                print(result.stdout.splitlines()[0], flush=True)
    assert all(digest(Path(p)) == h for p, h in hashes.items())
    (out/'results.json').write_text(json.dumps({'passed': True, 'source_sha256': hashes,
        'scope': 'Boundary injection; protocol engines qualified separately with assertions enabled',
        'tests': rows}, indent=2)+'\n')


if __name__ == '__main__':
    main()
