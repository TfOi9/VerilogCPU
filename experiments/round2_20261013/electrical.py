#!/usr/bin/env python3
"""Audit mapped netlists with their exact Liberty files and original SDC."""
import argparse
import json
from pathlib import Path
import re
import sys
from setup import ROOT, OUT, digest
from run import execute

LIMIT = 1000000
ROW = re.compile(r'^\s*(\S+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+\(VIOLATED\)\s*$', re.M)

def parse(text, kind):
    start, end = kind.upper()+'_BEGIN', kind.upper()+'_END'
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError('missing electrical report markers for '+kind)
    section = text.split(start,1)[1].split(end,1)[0]
    rows = [dict(pin=m[1], limit=float(m[2]), actual=float(m[3]), slack=float(m[4])) for m in ROW.finditer(section)]
    if len(rows) != section.count('(VIOLATED)') or len(rows) >= LIMIT:
        raise ValueError('unparsed or truncated electrical report')
    for row in rows:
        row['ratio'] = row['actual']/row['limit'] if row['limit'] else None
    return {'violating_pins':len(rows), 'units':'fF' if kind=='cap' else 'ns',
            'worst_slack':min(rows, key=lambda r:r['slack']) if rows else None,
            'worst_ratio':max(rows, key=lambda r:r['ratio'] or 0) if rows else None,
            'worst_20':sorted(rows, key=lambda r:r['slack'])[:20]}

def audit(mapped_dir, output):
    output.mkdir(parents=True, exist_ok=True)
    original = (mapped_dir/'timing.tcl').read_text()
    # Reuse libraries and netlist; never source the timing script that writes baseline artifacts.
    script = original[:original.index('source ')]
    script += 'read_sdc "'+str(mapped_dir/'constraints.sdc')+'"\n'
    for label, option in [('cap','max_capacitance'),('slew','max_slew')]:
        script += f'puts "{label.upper()}_BEGIN"\nreport_check_types -{option} -violators -max_count {LIMIT} -digits 6 -no_line_splits\nputs "{label.upper()}_END"\n'
    script += 'puts "FANOUT_BEGIN"\nreport_check_types -max_fanout -max_count 1000000 -digits 6 -no_line_splits\nputs "FANOUT_END"\n'
    script += '} message]} { puts stderr "CHECK_ERROR $message"; exit 1 }\nexit 0\n'
    path = output/'audit.tcl'
    path.write_text(script)
    files = [mapped_dir/'mapped.v', mapped_dir/'constraints.sdc']
    files += [Path(p) for p in re.findall(r'read_liberty "([^"]+)"', original)]
    hashes = {str(p):digest(p) for p in files}
    execution = execute([ROOT/'.deps/opensta/bin/sta','-no_init','-exit',path], output/'audit.log', 180)
    text = (output/'audit.log').read_text()
    if re.search(r'(?m)^(Error|CHECK_ERROR|ERROR)\b', text):
        raise ValueError('OpenSTA reported an error')
    cap, slew = parse(text,'cap'), parse(text,'slew')
    fanout = text.split('FANOUT_BEGIN',1)[1].split('FANOUT_END',1)[0].strip()
    result = {'completed':True, 'electrical_pass':cap['violating_pins']==0 and slew['violating_pins']==0,
              'max_capacitance':cap, 'max_slew':slew,
              'max_fanout_status':'not_constrained' if not fanout else 'see_raw_report',
              'input_sha256':hashes, 'execution':execution,
              'scope':'pre-layout mapped Liberty/SDC check; no extracted interconnect parasitics'}
    if hashes != {str(p):digest(p) for p in files}:
        raise ValueError('electrical inputs changed during analysis')
    (output/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(str(output), 'cap',cap['violating_pins'],'slew',slew['violating_pins'],flush=True)
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--mapped-dir',type=Path)
    parser.add_argument('--out',type=Path)
    args = parser.parse_args()
    if args.mapped_dir:
        audit(args.mapped_dir.resolve(), args.out.resolve())
    else:
        for path in sorted(OUT.glob('*/synth/*/opt/report.json')):
            audit(path.parent, path.parent.parent/'electrical')
