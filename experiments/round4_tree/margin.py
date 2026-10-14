#!/usr/bin/env python3
"""Close hold to a positive nominal target while preserving all state boundaries."""
import json
from pathlib import Path
import re
from stage import ROOT, OUT
from repair import execute, evaluate_full, refine_electrical, is_fixed
from hold import audit_hold, instance_map, resolve_pin

TARGET_NS = 0.020
LIMIT = 1000000


def audit(directory):
    hold = audit_hold(directory)
    script = (directory/'hold.tcl').read_text()
    begin = script.index('report_checks ')
    end = script.index('\n', begin)
    command = ('report_checks -path_delay min -sort_by_slack -group_path_count '+str(LIMIT)+
               ' -endpoint_path_count 1 -slack_max '+str(TARGET_NS)+
               ' -format json > '+str(directory/'margin_paths.json'))
    script = script[:begin]+command+script[end:]
    path = directory/'margin.tcl'
    path.write_text(script)
    execute([ROOT/'.deps/opensta/bin/sta', '-no_init', '-exit', path], directory/'margin.log', 180)
    text = (directory/'margin.log').read_text()
    if re.search(r'(?m)^(Error|HOLD_ERROR)\b', text):
        raise ValueError('margin query failed')
    checks = json.loads((directory/'margin_paths.json').read_text())['checks']
    if len(checks) >= LIMIT:
        raise ValueError('margin report may be truncated')
    rows = [{'pin': c['endpoint'], 'slack_ns': c['slack']*1e9} for c in checks]
    if any(r['slack_ns'] > TARGET_NS+1e-6 for r in rows):
        raise ValueError('unexpected margin query units')
    result = {'completed': True, 'target_ns': TARGET_NS, 'below_target_paths': len(rows),
              'worst_slack_ns': hold['worst_slack_ns'], 'hold_violations': hold['violating_endpoints'],
              'passed': hold['passed'] and not rows and hold['worst_slack_ns'] >= TARGET_NS,
              'rows': rows, 'scope': hold['scope']}
    (directory/'margin.json').write_text(json.dumps(result, indent=2)+'\n')
    print('MARGIN', directory, len(rows), hold['worst_slack_ns'], flush=True)
    return result


def close(original, current, output):
    output.mkdir(parents=True, exist_ok=True)
    history = []
    for iteration in range(5):
        margin = audit(current)
        history.append({'directory': str(current), 'below_target_paths': margin['below_target_paths'],
                        'hold_violations': margin['hold_violations'], 'worst_slack_ns': margin['worst_slack_ns']})
        if margin['passed']:
            break
        if iteration == 4 or not margin['rows']:
            raise ValueError('positive hold margin did not converge')
        source = json.loads((current/'design.json').read_text())
        top = source['modules']['student_top']
        names = instance_map(top, (current/'mapped.v').read_text())
        drivers = {b: (name, p) for name, c in top['cells'].items() for p, bits in c['connections'].items()
                   if c['port_directions'][p] == 'output' for b in bits if isinstance(b, int)}
        nets = {resolve_pin(top, names, row['pin']) for row in margin['rows']}
        next_bit = max(b for n in top['netnames'].values() for b in n['bits'] if isinstance(b, int))+1
        changes = []
        for bit in sorted(nets):
            if bit not in drivers or is_fixed(top['cells'][drivers[bit][0]]):
                raise ValueError('direct PI/state path requires a separate pin-specific proof')
            name, pin = drivers[bit]
            cell = top['cells'][name]
            if cell['connections'][pin] != [bit]:
                raise ValueError('multi-bit driver unsupported')
            internal = list(range(next_bit, next_bit+4))
            next_bit += 4
            cell['connections'][pin] = [internal[0]]
            prefix = f'repair.margin{iteration}_{bit}_'
            for i, kind in enumerate(['BUFx2_ASAP7_75t_R']*3+['BUFx8_ASAP7_75t_R']):
                target = internal[i+1] if i < 3 else bit
                top['cells'][prefix+str(i)] = {'hide_name': 0, 'type': kind, 'parameters': {}, 'attributes': {},
                    'port_directions': {'A': 'input', 'Y': 'output'}, 'connections': {'A': [internal[i]], 'Y': [target]}}
                top['netnames'][prefix+'wire'+str(i)] = {'hide_name': 0, 'bits': [internal[i]], 'attributes': {}}
            changes.append({'driver': name, 'bit': bit, 'action': 'four_stage_positive_hold_padding'})
        following = output/('margin'+str(iteration+1))
        evaluate_full(original, following, source)
        (following/'changes.json').write_text(json.dumps(changes, indent=2)+'\n')
        electrical = refine_electrical(original, following)
        if not electrical['electrical_pass']:
            raise ValueError('hold padding did not close electrical constraints')
        current = Path(electrical['final_directory'])
    result = {'completed': True, 'passed': margin['passed'], 'target_ns': TARGET_NS,
              'final_directory': str(current), 'history': history}
    (output/'closure.json').write_text(json.dumps(result, indent=2)+'\n')
    return result
