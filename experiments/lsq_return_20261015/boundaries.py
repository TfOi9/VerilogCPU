#!/usr/bin/env python3
"""Report the cache ID to LSQ address path without changing official artifacts."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'experiments/round3_electrical'))
from hold import instance_map, resolve_pin


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ppa', type=Path, required=True)
    parser.add_argument('--preabc', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    ppa, out = args.ppa.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    official = {str(p): digest(p) for p in ppa.iterdir() if p.is_file()}
    top = json.loads((ppa/'design.json').read_text())['modules']['student_top']
    pre = json.loads(args.preabc.read_text())['modules']['student_top']
    names = instance_map(top, (ppa/'mapped.v').read_text())
    instances = {v: k for k, v in names.items()}
    aliases = {}
    for name, net in pre['netnames'].items():
        if name == 'dcache.r_id' or name.startswith('core.lsq.address['):
            for i, bit in enumerate(net['bits']):
                aliases.setdefault(bit, []).append(name+(f'[{i}]' if len(net['bits']) > 1 else ''))
    inversions = {c['connections']['A'][0]: c['connections']['Y'][0]
                  for c in pre['cells'].values() if c['type'] == '$_NOT_'}
    starts, ends, labels = [], [], {}
    for name, cell in pre['cells'].items():
        if not cell['type'].startswith('DFF'):
            continue
        for port, bits in cell['connections'].items():
            if cell['port_directions'][port] != 'output':
                continue
            assert len(bits) == 1
            state = aliases.get(bits[0], [])+aliases.get(inversions.get(bits[0]), [])
            if not state:
                continue
            assert name in top['cells'] and cell['type'] == top['cells'][name]['type']
            assert cell.get('attributes') == top['cells'][name].get('attributes')
            if any(n.startswith('dcache.r_id[') for n in state):
                pin = instances[name]+'/'+port
                starts.append(pin)
            else:
                pin = instances[name]+'/D'
                ends.append(pin)
            labels[pin] = state
    assert len(starts) == 2 and len(ends) == 256, (len(starts), len(ends))
    script = (ppa/'timing.tcl').read_text().split('\nsource ', 1)[0]+'\n'
    script += 'read_sdc "'+str(ppa/'constraints.sdc')+'"\n'
    selector = '-from [get_pins {'+' '.join(starts)+'}] -to [get_pins {'+' '.join(ends)+'}]'
    script += 'report_checks '+selector+' -path_delay max -sort_by_slack -group_path_count 5 -format json > "'+str(out/'paths.json')+'"\n'
    script += 'report_checks '+selector+' -path_delay max -sort_by_slack -group_path_count 5 -fields {slew cap fanout} > "'+str(out/'paths.rpt')+'"\n'
    script += '} message]} { puts stderr $message; exit 1 }\nexit 0\n'
    (out/'timing.tcl').write_text(script)
    command = ['timeout', '-k', '5', '180', str(ROOT/'.deps/opensta/bin/sta'), '-exit', str(out/'timing.tcl')]
    (out/'command.json').write_text(json.dumps(command, indent=2)+'\n')
    with (out/'timing.log').open('w') as log:
        run = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    assert run.returncode == 0 and 'Error:' not in (out/'timing.log').read_text()
    checks = json.loads((out/'paths.json').read_text())['checks']
    assert len(checks) == 5
    fanout = Counter(b for c in top['cells'].values() for p, bs in c['connections'].items()
                     if c['port_directions'][p] == 'input' for b in bs)
    paths = []
    for check in checks:
        stages = [after for before, after in zip(check['source_path'], check['source_path'][1:])
                  if after['instance'] and before['instance'] == after['instance'] and not after['cell'].startswith('DFF')]
        paths.append({'start': {'pin': check['startpoint'], 'rtl_state': labels[check['startpoint']]},
                      'end': {'pin': check['endpoint'], 'rtl_state': labels[check['endpoint']]},
                      'arrival_ns': check['source_path'][-1]['arrival']*1e9,
                      'combinational_stages': len(stages),
                      'max_path_fanout': max(fanout[resolve_pin(top, names, s['pin'])] for s in stages)})
    assert all(digest(Path(p)) == h for p, h in official.items())
    inputs = [Path(__file__), ROOT/'experiments/round3_electrical/hold.py', args.preabc.resolve()]
    result = {'completed': True, 'passed': True,
              'scope': 'diagnostic STA using the official netlist, libraries and SDC; official files unchanged',
              'startpoints': len(starts), 'endpoints': len(ends), 'paths': paths,
              'official_sha256': official, 'source_sha256': {str(p): digest(p) for p in inputs},
              'artifact_sha256': {str(p): digest(p) for p in out.iterdir() if p.is_file()}}
    (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(paths[0], indent=2), flush=True)


if __name__ == '__main__':
    main()
