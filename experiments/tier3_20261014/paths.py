#!/usr/bin/env python3
"""Correlate preserved state cells with a repeated pre-ABC synthesis stage."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/tier3-20261014'
PPA = ROOT/'build/hum-20261014/ppa-v6'
sys.path.insert(0, str(ROOT/'experiments/round3_electrical'))
from hold import instance_map, resolve_pin


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    final = PPA/'hold/margin1'
    original = json.loads((PPA/'mapping/opt/design.json').read_text())['modules']['student_top']
    top = json.loads((final/'design.json').read_text())['modules']['student_top']
    pre = json.loads((OUT/'preabc.json').read_text())['modules']['student_top']
    names = instance_map(top, (final/'mapped.v').read_text())
    aliases = {}
    for name, net in pre['netnames'].items():
        if not net.get('hide_name'):
            for i, bit in enumerate(net['bits']):
                aliases.setdefault(bit, []).append(name+(f'[{i}]' if len(net['bits']) > 1 else ''))
    inversions = {c['connections']['A'][0]: c['connections']['Y'][0]
                  for c in pre['cells'].values() if c['type'] == '$_NOT_'}

    def describe(pin):
        instance = pin.rsplit('/', 1)[0]
        name = names.get(instance, instance)
        cell = top['cells'][name]
        prior, premapped = original['cells'][name], pre['cells'][name]
        assert cell['type'] == prior['type'] == premapped['type']
        assert cell.get('attributes') == prior.get('attributes') == premapped.get('attributes')
        assert {p: len(b) for p, b in cell['connections'].items()} == {
            p: len(b) for p, b in premapped['connections'].items()}
        outputs = [b for p, bits in premapped['connections'].items()
                   if premapped['port_directions'][p] == 'output' for b in bits]
        state_names = [n for b in outputs for n in aliases.get(b, [])]
        state_names += [n for b in outputs for n in aliases.get(inversions.get(b), [])]
        assert state_names
        return {'pin': pin, 'preserved_cell': name, 'rtl_state': state_names,
                'src': cell.get('attributes', {}).get('src')}

    fanout = Counter(b for c in top['cells'].values() for p, bits in c['connections'].items()
                     if c['port_directions'][p] == 'input' for b in bits)
    paths = []
    for check in json.loads((final/'critical_paths.json').read_text())['checks']:
        stages = []
        for before, after in zip(check['source_path'], check['source_path'][1:]):
            if not after['instance'] or before['instance'] != after['instance']:
                continue
            if after['cell'].startswith('DFF'):
                continue
            stages.append({'pin': after['pin'], 'cell': after['cell'],
                'delay_ns': (after['arrival']-before['arrival'])*1e9,
                'fanout': fanout[resolve_pin(top, names, after['pin'])]})
        paths.append({'start': describe(check['startpoint']), 'end': describe(check['endpoint']),
            'arrival_ns': check['source_path'][-1]['arrival']*1e9,
            'combinational_stages': len(stages),
            'buffers_inverters': sum(s['cell'].startswith(('BUF', 'INV')) for s in stages),
            'max_path_fanout': max(s['fanout'] for s in stages),
            'largest_stages': sorted(stages, key=lambda x: -x['delay_ns'])[:5]})
    files = [final/f for f in ('design.json', 'mapped.v', 'critical_paths.json')]
    files += [OUT/'preabc.json', OUT/'preabc.ys', OUT/'preabc.log',
              PPA/'mapping/opt/design.json', Path(__file__)]
    result = {'completed': True, 'passed': True, 'paths': paths,
              'source_sha256': {str(p): digest(p) for p in files}}
    (OUT/'path-audit.json').write_text(json.dumps(result, indent=2)+'\n')
    print(paths[0])


if __name__ == '__main__':
    main()
