#!/usr/bin/env python3
"""Replay only the pre-ABC prefix to recover public state names for 4x4 paths."""
import argparse
import json
from pathlib import Path
from stage import ROOT, OUT, stage, digest
from repair import execute


def recover(variant):
    config = '4x4-p64-r16'
    source = OUT/'common-synth'/variant/config/'opt'
    out = OUT/'provenance'/variant/config
    out.mkdir(parents=True, exist_ok=True)
    target = out/'state.json'
    commands = (source/'synth.ys').read_text().splitlines()
    last = next(i for i, command in enumerate(commands) if command.startswith('dfflibmap '))
    prefix = commands[:last+1]+['write_json '+str(target)]
    script = out/'replay.ys'
    script.write_text('\n'.join(prefix)+'\n')
    if not target.exists():
        execute([ROOT/'.deps/yosys/bin/yosys', '-Q', '-T', '-s', script], out/'replay.log', 900)
    state = json.loads(target.read_text())['modules']['student_top']
    record = json.loads((OUT/'common-qualified'/variant/config/'run.json').read_text())
    final = Path(record['final_directory'])
    path = json.loads((final/'path-audit.json').read_text())['checks'][0]
    raw = json.loads((source/'design.json').read_text())['modules']['student_top']
    result = {}
    for point in ('start', 'end'):
        name = path[point]['original_name']
        cell = state['cells'][name]
        if cell['type'] != raw['cells'][name]['type']:
            raise ValueError('state cell replay type mismatch')
        bits = {b for p, bs in cell['connections'].items() if cell['port_directions'][p] == 'output' for b in bs}
        for c in state['cells'].values():
            if c['type'].startswith(('$_NOT_', '$_BUF_', 'INV', 'BUF')) and any(b in bits for b in c['connections'].get('A', [])):
                bits.update(c['connections'].get('Y', []))
        aliases = [n+(f'[{i}]' if len(net['bits']) > 1 else '') for n, net in state['netnames'].items()
                   if not net.get('hide_name') for i, b in enumerate(net['bits']) if b in bits]
        result[point] = {'cell': name, 'type': cell['type'], 'state_output_aliases': sorted(aliases),
                         'attributes': cell.get('attributes', {})}
        if not aliases:
            raise ValueError('replay did not recover a public state alias')
    data = {'variant': variant, 'config': config, 'points': result,
            'artifact_sha256': {str(p): digest(p) for p in (source/'synth.ys', source/'design.json', target,
                                                           final/'path-audit.json', script)}}
    (out/'result.json').write_text(json.dumps(data, indent=2)+'\n')
    print(variant, {p: value['state_output_aliases'][:8] for p, value in result.items()}, flush=True)
    return data


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--variants', nargs='+', default=['baseline', 'tree-wb'])
    args = parser.parse_args()
    stage()
    for v in args.variants:
        recover(v)
