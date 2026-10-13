#!/usr/bin/env python3
"""Audit and repair real hold violations without changing state or SDC budgets."""
import argparse
import json
from pathlib import Path
import re
from repair import ROOT,OUT,evaluate_full,refine_electrical,is_fixed
from run import execute

ROW=re.compile(r'^\s*(\S+)\s+\(([^)]+)\)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+\(VIOLATED\)\s*$',re.M)

def audit_hold(mapped_dir):
    script=(mapped_dir/'timing.tcl').read_text()
    script=script[:script.index('source ')]+'read_sdc "'+str(mapped_dir/'constraints.sdc')+'"\n'
    script+='report_checks -path_delay min -sort_by_slack -group_path_count 5 -format json > '+str(mapped_dir/'hold_paths.json')+'\n'
    script+='report_check_types -min_delay -violators -format end -max_count 1000000 -digits 6 -no_line_splits > '+str(mapped_dir/'hold.rpt')+'\n'
    script+='} message]} { puts stderr "HOLD_ERROR $message"; exit 1 }\nexit 0\n'
    path=mapped_dir/'hold.tcl'
    path.write_text(script)
    execute([ROOT/'.deps/opensta/bin/sta','-no_init','-exit',path],mapped_dir/'hold.log',180)
    log=(mapped_dir/'hold.log').read_text()
    if re.search(r'(?m)^(Error|HOLD_ERROR)\b',log):
        raise ValueError('OpenSTA hold query failed')
    text=(mapped_dir/'hold.rpt').read_text()
    rows=[{'pin':m[1],'cell':m[2],'required_ns':float(m[3]),'actual_ns':float(m[4]),'slack_ns':float(m[5])} for m in ROW.finditer(text)]
    if len(rows)!=text.count('(VIOLATED)') or len(rows)>=1000000:
        raise ValueError('unparsed or truncated hold report')
    checks=json.loads((mapped_dir/'hold_paths.json').read_text())['checks']
    if not checks:
        raise ValueError('hold paths missing on sequential CPU')
    worst=min(c['slack']*1e9 for c in checks)
    result={'completed':True,'passed':not rows and worst>=0,'violating_endpoints':len(rows),'worst_slack_ns':worst,
            'rows':rows,'scope':'original SDC, ideal clock, no extracted parasitics'}
    (mapped_dir/'hold.json').write_text(json.dumps(result,indent=2)+'\n')
    print('HOLD',mapped_dir,len(rows),worst,flush=True)
    return result

def instance_map(top,mapped_verilog):
    mapped=re.findall(r'^  (\S+) (_\d+_) \(',mapped_verilog,re.M)
    hidden=[(n,c) for n,c in sorted(top['cells'].items()) if c.get('hide_name')]
    if len(mapped)!=len(hidden):
        raise ValueError('hidden cell count differs')
    result={}
    for (kind,instance),(name,cell) in zip(mapped,hidden):
        if kind!=cell['type']:
            raise ValueError('hidden cell type differs')
        result[instance]=name
    return result

def resolve_pin(top,names,pin):
    if '/' in pin:
        name,port=pin.rsplit('/',1)
        name=names.get(name,name)
        connection=top['cells'][name]['connections']
    else:
        port=pin
        connection={n:p['bits'] for n,p in top['ports'].items()}
    index=re.fullmatch(r'(\w+)\[(\d+)]',port)
    port,bit=(index[1],int(index[2])) if index else (port,0)
    return connection[port][bit]

def close_hold(original,current,out,max_rounds=3):
    out.mkdir(parents=True,exist_ok=True)
    history=[]
    for iteration in range(max_rounds+1):
        hold=audit_hold(current)
        history.append({'directory':str(current),'violating_endpoints':hold['violating_endpoints'],'worst_slack_ns':hold['worst_slack_ns']})
        if hold['passed'] or iteration==max_rounds:
            break
        source=json.loads((current/'design.json').read_text())
        top=source['modules']['student_top']
        names=instance_map(top,(current/'mapped.v').read_text())
        driver={b:(name,p) for name,c in top['cells'].items() for p,bits in c['connections'].items()
                if c['port_directions'][p]=='output' for b in bits if isinstance(b,int)}
        nets={resolve_pin(top,names,row['pin']) for row in hold['rows']}
        next_bit=max(b for n in top['netnames'].values() for b in n['bits'] if isinstance(b,int))+1
        changes=[]
        for bit in sorted(nets):
            if bit not in driver:
                raise ValueError('hold violation directly driven by primary input; pin-specific proof required')
            name,p=driver[bit]
            cell=top['cells'][name]
            if is_fixed(cell):
                raise ValueError('hold violation directly driven by fixed state; pin-specific proof required')
            if cell['connections'][p]!=[bit]:
                raise ValueError('multi-bit hold driver unsupported')
            internal=list(range(next_bit,next_bit+4))
            next_bit+=4
            cell['connections'][p]=[internal[0]]
            prefix=f'repair.hold{iteration}_{bit}_'
            for i,kind in enumerate(['BUFx2_ASAP7_75t_R']*3+['BUFx8_ASAP7_75t_R']):
                src=internal[i]
                dst=internal[i+1] if i<3 else bit
                top['cells'][prefix+str(i)]={'hide_name':0,'type':kind,'parameters':{},'attributes':{},
                    'port_directions':{'A':'input','Y':'output'},'connections':{'A':[src],'Y':[dst]}}
                top['netnames'][prefix+'wire'+str(i)]={'hide_name':0,'bits':[src],'attributes':{}}
            changes.append({'driver':name,'bit':bit,'action':'four_stage_hold_padding'})
        following=out/('hold'+str(iteration+1))
        evaluate_full(original,following,source)
        (following/'changes.json').write_text(json.dumps(changes,indent=2)+'\n')
        cap=refine_electrical(original,following)
        if not cap['electrical_pass']:
            raise ValueError('hold padding failed electrical closure')
        current=Path(cap['final_directory'])
    final={'completed':True,'passed':history[-1]['violating_endpoints']==0 and history[-1]['worst_slack_ns']>=0,
           'final_directory':str(current),'history':history}
    (out/'closure.json').write_text(json.dumps(final,indent=2)+'\n')
    return final

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--original',type=Path,required=True)
    parser.add_argument('--current',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    result=close_hold(args.original.resolve(),args.current.resolve(),args.out.resolve())
    raise SystemExit(0 if result['passed'] else 1)
