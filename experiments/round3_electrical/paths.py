#!/usr/bin/env python3
"""Describe repaired critical paths using retained state boundary provenance."""
from collections import Counter
import json
from pathlib import Path
import re
from repair import OUT, digest, is_fixed
from hold import instance_map, resolve_pin


def audit(directory):
    top = json.loads((directory/'design.json').read_text())['modules']['student_top']
    names = instance_map(top, (directory/'mapped.v').read_text())
    fanout = Counter()
    aliases = {}
    for cell in top['cells'].values():
        for port, bits in cell['connections'].items():
            if cell['port_directions'][port] == 'input':
                fanout.update(bits)
    for name, net in top['netnames'].items():
        if net.get('hide_name') or name.startswith(('repair.', 'fixed_bit_')):
            continue
        for i, bit in enumerate(net['bits']):
            aliases.setdefault(bit, []).append(name+(f'[{i}]' if len(net['bits']) > 1 else ''))

    def describe(pin):
        bit = resolve_pin(top, names, pin)
        if '/' not in pin:
            return {'pin': pin, 'cell': 'port', 'aliases': aliases.get(bit, [])}
        instance = pin.rsplit('/', 1)[0]
        name = names.get(instance, instance)
        cell = top['cells'][name]
        return {'pin': pin, 'cell': cell['type'], 'original_name': name,
                'fixed_boundary': is_fixed(cell), 'attributes': cell.get('attributes', {}),
                'aliases': aliases.get(bit, [])}

    result = []
    for check in json.loads((directory/'critical_paths.json').read_text())['checks']:
        stages = []
        points = check['source_path']
        for before, after in zip(points, points[1:]):
            if not after['instance'] or before['instance'] != after['instance']:
                continue
            desc = describe(after['pin'])
            if desc['fixed_boundary']:
                continue
            bit = resolve_pin(top, names, after['pin'])
            stages.append(dict(desc, delay_ns=(after['arrival']-before['arrival'])*1e9,
                               fanout=fanout[bit], cap_ff=after.get('capacitance', 0)*1e15,
                               slew_ns=after.get('slew', 0)*1e9))
        result.append({'start': describe(check['startpoint']), 'end': describe(check['endpoint']),
                       'arrival_ns': points[-1]['arrival']*1e9,
                       'combinational_stages': len(stages),
                       'buffer_inverter_stages': sum(s['cell'].startswith(('BUF', 'INV')) for s in stages),
                       'cell_delay_sum_ns': sum(s['delay_ns'] for s in stages),
                       'largest_stages': sorted(stages, key=lambda s: -s['delay_ns'])[:8]})
    if not result or any(not r['combinational_stages'] for r in result):
        raise ValueError('critical path correlation incomplete')
    data = {'checks': result, 'artifact_sha256': {str(directory/f): digest(directory/f)
            for f in ('critical_paths.json', 'mapped.v', 'design.json')}}
    (directory/'path-audit.json').write_text(json.dumps(data, indent=2)+'\n')
    return data


if __name__ == '__main__':
    for run in json.loads((OUT/'closed-summary.json').read_text()):
        data = audit(Path(run['final_directory']))
        first = data['checks'][0]
        print(run['variant'], run['config'], first['combinational_stages'],
              first['start']['original_name'], '->', first['end']['original_name'])
