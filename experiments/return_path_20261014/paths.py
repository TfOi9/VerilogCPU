#!/usr/bin/env python3
"""Identify preserved endpoint state from an exact pre-ABC diagnostic replay."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/return-path-20261014'
PPA = ROOT/'build/load-nonoverlap-20261014/candidate/ppa/opt'
sys.path.insert(0, str(ROOT/'experiments/round3_electrical'))
from hold import instance_map


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    top = json.loads((PPA/'design.json').read_text())['modules']['student_top']
    pre = json.loads((OUT/'preabc.json').read_text())['modules']['student_top']
    names = instance_map(top, (PPA/'mapped.v').read_text())
    aliases = {}
    for name, net in pre['netnames'].items():
        if not net.get('hide_name'):
            for i, bit in enumerate(net['bits']):
                aliases.setdefault(bit, []).append(name+(f'[{i}]' if len(net['bits']) > 1 else ''))
    inversions = {c['connections']['A'][0]: c['connections']['Y'][0]
        for c in pre['cells'].values() if c['type'] == '$_NOT_'}

    def describe(pin):
        key = names[pin.rsplit('/', 1)[0]]
        cell, prior = top['cells'][key], pre['cells'][key]
        assert cell['type'] == prior['type']
        assert cell.get('attributes') == prior.get('attributes')
        assert {p: len(b) for p, b in cell['connections'].items()} == {
            p: len(b) for p, b in prior['connections'].items()}
        outputs = [b for p, bits in prior['connections'].items()
            if prior['port_directions'][p] == 'output' for b in bits]
        state = [n for b in outputs for n in aliases.get(b, [])]
        state += [n for b in outputs for n in aliases.get(inversions.get(b), [])]
        assert state, pin
        return {'pin': pin, 'preserved_cell': key, 'rtl_state': state,
                'src': cell.get('attributes', {}).get('src')}

    paths = [{'start': describe(c['startpoint']), 'end': describe(c['endpoint']),
              'arrival_ns': c['source_path'][-1]['arrival']*1e9}
             for c in json.loads((PPA/'critical_paths.json').read_text())['checks']]
    files = [PPA/n for n in ('design.json', 'mapped.v', 'critical_paths.json', 'synth.ys')]
    files += [OUT/n for n in ('preabc.json', 'preabc.ys', 'preabc.log')]
    files += [Path(__file__), ROOT/'experiments/round3_electrical/hold.py']
    (OUT/'path-audit.json').write_text(json.dumps({'completed': True, 'passed': True,
        'scope': 'diagnostic replay; official PPA artifacts unchanged', 'paths': paths,
        'source_sha256': {str(p): digest(p) for p in files}}, indent=2)+'\n')
    print(json.dumps(paths[0], indent=2))


if __name__ == '__main__':
    main()
