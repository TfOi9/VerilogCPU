#!/usr/bin/env python3
"""Correlate official critical endpoints with a preserved pre-ABC replay."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'experiments/round3_electrical'))
from hold import instance_map


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ppa', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    ppa, out = args.ppa.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    official = {str(p): digest(p) for p in ppa.iterdir() if p.is_file()}
    script = (ppa/'synth.ys').read_text().split('\nabc -exe ', 1)[0]
    assert 'dfflibmap ' in script and '\nwrite_json ' not in script
    script += '\nwrite_json "'+str(out/'preabc.json')+'"\n'
    (out/'preabc.ys').write_text(script)
    command = ['timeout', '-k', '5', '600', str(ROOT/'.deps/yosys/bin/yosys'),
               '-Q', '-T', '-q', '-s', str(out/'preabc.ys')]
    (out/'command.json').write_text(json.dumps(command, indent=2)+'\n')
    with (out/'preabc.log').open('w') as log:
        process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    assert process.returncode == 0
    top = json.loads((ppa/'design.json').read_text())['modules']['student_top']
    pre = json.loads((out/'preabc.json').read_text())['modules']['student_top']
    names = instance_map(top, (ppa/'mapped.v').read_text())
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
        bits = [b for p, bs in prior['connections'].items()
                if prior['port_directions'][p] == 'output' for b in bs]
        state = [n for b in bits for n in aliases.get(b, [])]
        state += [n for b in bits for n in aliases.get(inversions.get(b), [])]
        assert state, pin
        return {'pin': pin, 'preserved_cell': key, 'rtl_state': state,
                'src': cell.get('attributes', {}).get('src')}

    checks = json.loads((ppa/'critical_paths.json').read_text())['checks']
    paths = [{'start': describe(c['startpoint']), 'end': describe(c['endpoint']),
              'arrival_ns': c['source_path'][-1]['arrival']*1e9} for c in checks]
    assert all(digest(Path(p)) == h for p, h in official.items())
    files = [Path(__file__), ROOT/'experiments/round3_electrical/hold.py',
             out/'preabc.ys', out/'preabc.log', out/'preabc.json']
    (out/'results.json').write_text(json.dumps({'completed': True, 'passed': True,
        'scope': 'diagnostic replay; official PPA artifacts unchanged', 'paths': paths,
        'official_sha256': official, 'source_sha256': {str(p): digest(p) for p in files}}, indent=2)+'\n')
    print(json.dumps(paths[0], indent=2))


if __name__ == '__main__':
    main()
