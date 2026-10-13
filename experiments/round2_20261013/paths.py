#!/usr/bin/env python3
"""Correlate STA paths with mapped cells, fanout and retained RTL provenance."""
from collections import Counter
import json
import re
from setup import OUT, digest

def audit(path):
    design = json.loads((path/'design.json').read_text())['modules']['student_top']
    cells = design['cells']
    mapped = re.findall(r'^  (\S+) (_\d+_) \(', (path/'mapped.v').read_text(), re.M)
    hidden = [(name,cell) for name,cell in sorted(cells.items()) if cell.get('hide_name')]
    if len(mapped) != len(hidden):
        raise ValueError('mapped cell count mismatch')
    names = {}
    for (kind,instance),(name,cell) in zip(mapped,hidden):
        if kind != cell['type']:
            raise ValueError('mapped cell ordering/type mismatch')
        names[instance] = dict(cell, original_name=name)
    fanout = Counter()
    aliases = {}
    for cell in cells.values():
        for port,bits in cell['connections'].items():
            if cell['port_directions'][port] == 'input':
                fanout.update(bits)
    for name,net in design['netnames'].items():
        if net.get('hide_name'):
            continue
        for i,bit in enumerate(net['bits']):
            aliases.setdefault(bit,[]).append(name+(f'[{i}]' if len(net['bits'])>1 else ''))
    def describe(pin):
        instance,port = pin.rsplit('/',1)
        cell = names[instance]
        return {'pin':pin,'cell':cell['type'],'original_name':cell['original_name'],
                'attributes':cell.get('attributes',{}),
                'aliases':[name for bit in cell['connections'][port] for name in aliases.get(bit,[])]}
    checks = json.loads((path/'critical_paths.json').read_text())['checks']
    result = []
    for check in checks:
        points = check['source_path']
        stages = []
        for before,after in zip(points,points[1:]):
            if before.get('instance') != after.get('instance') or after['instance'] not in names:
                continue
            cell = names[after['instance']]
            port = after['pin'].rsplit('/',1)[1]
            stages.append(dict(describe(after['pin']),delay_ns=(after['arrival']-before['arrival'])*1e9,
                fanout=sum(fanout[b] for b in cell['connections'][port]),
                cap_ff=after.get('capacitance',0)*1e15,slew_ns=after.get('slew',0)*1e9))
        result.append({'start':describe(check['startpoint']),'end':describe(check['endpoint']),
                       'largest_stages':sorted(stages,key=lambda s:-s['delay_ns'])[:5]})
    data = {'checks':result,'artifact_sha256':{str(path/f):digest(path/f) for f in ('critical_paths.json','mapped.v','design.json')}}
    (path.parent/'path-audit.json').write_text(json.dumps(data,indent=2)+'\n')
    return data

if __name__ == '__main__':
    for path in sorted(OUT.glob('*/synth/*/opt/critical_paths.json')):
        audit(path.parent)
        print(path.parent.parent,flush=True)
