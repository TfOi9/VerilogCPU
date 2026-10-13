#!/usr/bin/env python3
"""Buffer and size mapped combinational logic while fixing all state boundaries."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
EXP = Path(__file__).resolve().parent
OUT = ROOT/'build/round3-electrical'
sys.path.insert(0,str(ROOT/'experiments/round2_20261013'))
from run import execute
from setup import verify
sys.path.insert(0,str(ROOT.parent/'RISC-V-CPU-2026/scripts'))
from timing import analyze
from synth_report import area_report
from electrical import audit

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def is_fixed(cell):
    return cell['type'].startswith(('DFF','fakeram_','TIE'))

def signal(bit,bit_names=None):
    if isinstance(bit,int):
        if bit_names is not None:
            return bit_names.get(bit,'r'+str(bit))
        return 'n'+str(bit)
    if bit not in ('0','1'):
        raise ValueError('unknown or high impedance bit at mapped boundary')
    return 'constant_'+bit

def boundary(top):
    inputs,outputs=set(),set()
    for port in top['ports'].values():
        if port['direction']=='inout':
            raise ValueError('inout is unsupported')
        (inputs if port['direction']=='input' else outputs).update(port['bits'])
    for cell in top['cells'].values():
        if is_fixed(cell):
            for port,bits in cell['connections'].items():
                (inputs if cell['port_directions'][port]=='output' else outputs).update(bits)
    # Literal constants remain constants, rather than unconstrained primary inputs.
    inputs={b for b in inputs if isinstance(b,int)}
    outputs={b for b in outputs if isinstance(b,int)}
    outputs-=inputs
    return inputs,outputs

def write_blif(top,path,bit_names=None):
    inputs,outputs=boundary(top)
    lines=['.model repair_region']
    for kind,bits in (('inputs',inputs),('outputs',outputs)):
        ordered=sorted(bits)
        if kind=='inputs':
            ordered+=['0','1']
        lines.append('.'+kind+' \\')
        for i in range(0,len(ordered),100):
            lines.append(' '.join(signal(b,bit_names) for b in ordered[i:i+100])+(' \\' if i+100<len(ordered) else ''))
    for name,cell in sorted(top['cells'].items()):
        if is_fixed(cell):
            continue
        pins=[]
        for port,bits in cell['connections'].items():
            if len(bits)!=1:
                raise ValueError('non-scalar technology pin '+name+'/'+port)
            pins.append(port+'='+signal(bits[0],bit_names))
        lines.append('.gate '+cell['type']+' '+' '.join(pins))
    lines.append('.end')
    path.write_text('\n'.join(lines)+'\n')
    return inputs,outputs

def yosys(command_lines,out,name):
    path=out/(name+'.ys')
    path.write_text('\n'.join(command_lines)+'\n')
    return execute([ROOT/'.deps/yosys/bin/yosys','-Q','-T','-s',path],out/(name+'.log'),180)

def quote(path):
    return '"'+str(path).replace('\\','\\\\').replace('"','\\"')+'"'

def merge_and_analyze(mapped_dir,out):
    source=json.loads((mapped_dir/'design.json').read_text())
    original=source['modules']['student_top']
    report=json.loads((mapped_dir/'report.json').read_text())
    libraries=[Path(x['path']) for x in report['libraries']]
    reads=['read_liberty -lib -ignore_miss_func '+quote(p) for p in libraries]
    region_path=out/'region.json'
    yosys([*reads,'read_verilog '+quote(out/'repair_region.v'),
           'hierarchy -check -top repair_region','check -assert -mapped',
           'write_json '+quote(region_path)],out,'region')
    region_design=json.loads(region_path.read_text())
    region=region_design['modules']['repair_region']
    mapping={}
    bridge=[]
    fixed_bits={b for p in original['ports'].values() for b in p['bits']}
    for c in original['cells'].values():
        if is_fixed(c):
            fixed_bits.update(b for bits in c['connections'].values() for b in bits)
    def bridge_output(src,dst):
        if isinstance(src,str):
            kind='TIEHIx1_ASAP7_75t_R' if src=='1' else 'TIELOx1_ASAP7_75t_R'
            pin='H' if src=='1' else 'L'
            bridge.append({'type':kind,'parameters':{},'attributes':{},'hide_name':0,
                           'port_directions':{pin:'output'},'connections':{pin:[dst]}})
        else:
            bridge.append({'type':'BUFxp67_ASAP7_75t_R','parameters':{},'attributes':{},'hide_name':0,
                           'port_directions':{'A':'input','Y':'output'},'connections':{'A':[src],'Y':[dst]}})
    for name,p in region['ports'].items():
        if len(p['bits'])!=1:
            raise ValueError('non-scalar cut boundary')
        target=int(name[1:]) if name.startswith('n') else name.rsplit('_',1)[1]
        bit=p['bits'][0]
        if isinstance(bit,str):
            if p['direction']!='output':
                raise ValueError('constant primary input in repaired netlist')
            bridge_output(bit,target)
        elif bit in mapping and mapping[bit]!=target:
            if p['direction']!='output':
                raise ValueError('aliased independent inputs')
            bridge_output(mapping[bit],target)
        else:
            mapping[bit]=target
    next_bit=max(b for n in original['netnames'].values() for b in n['bits'] if isinstance(b,int))+1
    def translate(bit):
        nonlocal next_bit
        if isinstance(bit,str):
            if bit not in ('0','1'):
                raise ValueError('undefined repaired connection')
            return bit
        if bit not in mapping:
            mapping[bit]=next_bit
            next_bit+=1
        return mapping[bit]
    fixed={name:c for name,c in original['cells'].items() if is_fixed(c)}
    original['cells']=dict(fixed)
    for name,c in region['cells'].items():
        c['connections']={port:[translate(b) for b in bits] for port,bits in c['connections'].items()}
        original['cells']['repair.'+name]=c
    for i,c in enumerate(bridge):
        original['cells']['repair.boundary_'+str(i)]=c
    original['netnames']={name:n for name,n in original['netnames'].items() if all(b in fixed_bits or isinstance(b,str) for b in n['bits'])}
    for bit in fixed_bits:
        if isinstance(bit,int):
            original['netnames']['fixed_bit_'+str(bit)]={'hide_name':0,'bits':[bit],'attributes':{}}
    for name,n in region['netnames'].items():
        n['bits']=[translate(b) for b in n['bits']]
        original['netnames']['repair.'+name]=n
    for name,module in region_design['modules'].items():
        if name!='repair_region':
            source['modules'][name]=module
    return evaluate_full(mapped_dir,out,source,len(bridge))

def evaluate_full(mapped_dir,out,source,alias_bridges=0):
    out.mkdir(parents=True,exist_ok=True)
    original=json.loads((mapped_dir/'design.json').read_text())['modules']['student_top']
    fixed={name:c for name,c in original['cells'].items() if is_fixed(c)}
    report=json.loads((mapped_dir/'report.json').read_text())
    libraries=[Path(x['path']) for x in report['libraries']]
    reads=['read_liberty -lib -ignore_miss_func '+quote(p) for p in libraries]
    merged=out/'merged.json'
    merged.write_text(json.dumps({'modules':{'student_top':source['modules']['student_top']}},separators=(',',':'))+'\n')
    libargs=' '.join('-liberty '+quote(p) for p in libraries)
    yosys([*reads,'read_json '+quote(merged),'hierarchy -check -top student_top',
           'check -assert -mapped',
           'tee -o '+quote(out/'stat.json')+' stat -json '+libargs,
           'write_json '+quote(out/'design.json'),'write_verilog -noattr -noexpr '+quote(out/'mapped.v')],out,'merge')
    actual=json.loads((out/'design.json').read_text())
    top=actual['modules']['student_top']
    anchors={n['bits'][0]:int(name[len('fixed_bit_'):]) for name,n in top['netnames'].items() if name.startswith('fixed_bit_')}
    ports={name:dict(p,bits=[anchors.get(b,b) for b in p['bits']]) for name,p in top['ports'].items()}
    if ports!=original['ports']:
        raise ValueError('top interface changed')
    actual_fixed={name:dict(c,connections={p:[anchors.get(b,b) for b in bits] for p,bits in c['connections'].items()})
                  for name,c in top['cells'].items() if is_fixed(c) and not name.startswith('repair.')}
    if actual_fixed!=fixed:
        raise ValueError('fixed state/constant cells changed after reconstruction')
    # Prove the reconstructed circuit, including aliases and constant boundaries.
    write_blif(original,out/'original.blif')
    reconstructed=out/'reconstructed.blif'
    write_blif(top,reconstructed,{b:'n'+str(old) for b,old in anchors.items()})
    libs=[p for p in libraries if '/.deps/' in str(p)]
    cec=out/'reconstruction.abc'
    cec.write_text('\n'.join(['read_lib '+str(p) if i==0 else 'read_lib -m '+str(p) for i,p in enumerate(libs)]+[
        'cec '+str(out/'original.blif')+' '+str(reconstructed)])+'\n')
    execute([ROOT/'.deps/yosys/bin/yosys-abc','-c','source '+str(cec)],out/'reconstruction-cec.log',180)
    if 'Networks are equivalent' not in (out/'reconstruction-cec.log').read_text():
        raise ValueError('reconstructed full-boundary equivalence failed')
    macros={r['module']:{k:r[k] for k in ('depth','width','area_um2')} for r in report['area']['sram_instances']}
    area=area_report(actual,json.loads((out/'stat.json').read_text()),macros)
    timing=analyze(str(ROOT/'.deps/opensta/bin/sta'),out,libraries,2.0,'clock')
    electrical=audit(out,out/'electrical')
    result={'completed':True,'source_mapped_dir':str(mapped_dir),'equivalence_passed':True,
            'fixed_cells':len(fixed),'alias_bridges':alias_bridges,'area':area,'timing':timing,
            'electrical':electrical,'cell_counts':dict(Counter(c['type'] for c in top['cells'].values())),
            'original_cell_counts':dict(Counter(c['type'] for c in json.loads((mapped_dir/'design.json').read_text())['modules']['student_top']['cells'].values()))}
    (out/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    print('REPAIRED',out,'Fmax',timing['estimated_fmax_mhz'],'area',area['area_um2'],
          'cap',electrical['max_capacitance']['violating_pins'],'slew',electrical['max_slew']['violating_pins'],flush=True)
    return result

def refine_electrical(mapped_dir,out,max_rounds=3):
    current=out
    history=[]
    for iteration in range(max_rounds+1):
        report=json.loads((current/'report.json').read_text())
        electrical=report['electrical']
        history.append({'directory':str(current),'cap_violations':electrical['max_capacitance']['violating_pins'],
                        'slew_violations':electrical['max_slew']['violating_pins']})
        if electrical['electrical_pass'] or iteration==max_rounds:
            break
        text=(current/'electrical/audit.log').read_text()
        from electrical import ROW
        pins={m[1] for m in ROW.finditer(text)}
        source=json.loads((current/'design.json').read_text())
        top=source['modules']['student_top']
        # Map writer-generated hidden instance names back to JSON cells.
        mapped=re.findall(r'^  (\S+) (_\d+_) \(', (current/'mapped.v').read_text(),re.M)
        hidden=[(n,c) for n,c in sorted(top['cells'].items()) if c.get('hide_name')]
        if len(mapped)!=len(hidden):
            raise ValueError('hidden instance mapping count mismatch')
        instance_map={}
        for (kind,instance),(name,cell) in zip(mapped,hidden):
            if kind!=cell['type']:
                raise ValueError('hidden instance mapping type mismatch')
            instance_map[instance]=name
        driver={b:(name,p) for name,c in top['cells'].items() for p,bits in c['connections'].items()
                if c['port_directions'][p]=='output' for b in bits if isinstance(b,int)}
        nets=set()
        for pin in pins:
            instance,p=pin.rsplit('/',1)
            name=instance_map.get(instance,instance)
            cell=top['cells'][name]
            nets.update(b for b in cell['connections'][p] if isinstance(b,int))
        next_bit=max(b for n in top['netnames'].values() for b in n['bits'] if isinstance(b,int))+1
        changes=[]
        for bit in sorted(nets):
            name,p=driver[bit]
            cell=top['cells'][name]
            if is_fixed(cell):
                raise ValueError('residual violation on fixed driver; tighten ABC input model: '+name)
            if cell['type']=='BUFx8_ASAP7_75t_R' and name.startswith('repair.drc'):
                cell['type']='BUFx16f_ASAP7_75t_R'
                changes.append({'driver':name,'action':'resize','cell':cell['type']})
                continue
            if cell['type']=='BUFx16f_ASAP7_75t_R' and name.startswith('repair.drc'):
                cell['type']='BUFx24_ASAP7_75t_R'
                changes.append({'driver':name,'action':'resize','cell':cell['type']})
                continue
            if cell['connections'][p]!=[bit]:
                raise ValueError('multi-bit output repair unsupported')
            first,second=next_bit,next_bit+1
            next_bit+=2
            cell['connections'][p]=[first]
            prefix='repair.drc'+str(iteration)+'_'+str(bit)
            for suffix,kind,src,dst in [('a','BUFx2_ASAP7_75t_R',first,second),('b','BUFx8_ASAP7_75t_R',second,bit)]:
                top['cells'][prefix+suffix]={'hide_name':0,'type':kind,'parameters':{},'attributes':{},
                    'port_directions':{'A':'input','Y':'output'},'connections':{'A':[src],'Y':[dst]}}
            for suffix,new_bit in [('input',first),('middle',second)]:
                top['netnames'][prefix+'_'+suffix]={'hide_name':0,'bits':[new_bit],'attributes':{}}
            changes.append({'driver':name,'action':'two_stage_output_buffer','bit':bit})
        following=out/('drc'+str(iteration+1))
        evaluate_full(mapped_dir,following,source)
        (following/'changes.json').write_text(json.dumps(changes,indent=2)+'\n')
        current=following
    result={'completed':True,'final_directory':str(current),'electrical_pass':history[-1]['cap_violations']==0 and history[-1]['slew_violations']==0,'history':history}
    (out/'closure.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

def repair(mapped_dir,out,fanout=8,slew=100,driver='INVx1_ASAP7_75t_R'):
    verify()
    out.mkdir(parents=True,exist_ok=True)
    source=json.loads((mapped_dir/'design.json').read_text())
    top=source['modules']['student_top']
    report=json.loads((mapped_dir/'report.json').read_text())
    libs=[Path(x['path']) for x in report['libraries'] if '/.deps/' in x['path']]
    if len(libs)!=5:
        raise ValueError('expected all five original standard-cell libraries')
    original=out/'original.blif'
    inputs,outputs=write_blif(top,original)
    commands=['read_lib '+str(p) if i==0 else 'read_lib -m '+str(p) for i,p in enumerate(libs)]
    if driver:
        constraints=out/'repair.constraints'
        constraints.write_text('set_driving_cell '+driver+'\nset_load 5\n')
        commands+=['read_constr '+str(constraints)]
    commands+=['read_blif '+str(original),'topo',f'buffer -p -N {fanout} -S {slew}',
               'upsize -D 2000 -T 30','stime','write_blif '+str(out/'repaired.blif'),
               'write_verilog '+str(out/'repair_region.v'),
               'cec '+str(original)+' '+str(out/'repaired.blif')]
    script=out/'repair.abc'
    script.write_text('\n'.join(commands)+'\n')
    execute([ROOT/'.deps/yosys/bin/yosys-abc','-c','source '+str(script)],out/'abc.log',600)
    text=(out/'abc.log').read_text()
    if 'Networks are equivalent' not in text:
        raise ValueError('ABC did not confirm combinational boundary equivalence: '+str(out/'abc.log'))
    (out/'boundary.json').write_text(json.dumps({'inputs':sorted(inputs),'outputs':sorted(outputs),
        'fixed_cell_sha256':{name:hashlib.sha256(json.dumps(cell,sort_keys=True).encode()).hexdigest() for name,cell in top['cells'].items() if is_fixed(cell)},
        'inputs_sha256':{str(p):digest(p) for p in [mapped_dir/'design.json',mapped_dir/'mapped.v',*libs]},
        'fanout_target':fanout,'slew_target_ps':slew,'abc_pi_driver':driver,
        'abc_output_load_ff':5 if driver else None,'equivalence_passed':True},indent=2)+'\n')
    print('ABC combinational equivalence passed:',out,flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--mapped-dir',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--fanout',type=int,default=8)
    parser.add_argument('--slew',type=int,default=100)
    parser.add_argument('--driver',default='INVx1_ASAP7_75t_R')
    args=parser.parse_args()
    repair(args.mapped_dir.resolve(),args.out.resolve(),args.fanout,args.slew,args.driver)
    merge_and_analyze(args.mapped_dir.resolve(),args.out.resolve())
    refine_electrical(args.mapped_dir.resolve(),args.out.resolve())
