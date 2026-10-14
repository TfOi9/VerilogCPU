#!/usr/bin/env python3
"""Profile six official workloads on frozen, bounded sensitivity experiments."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('pilot', ROOT/'experiments/cache_20261014/run.py')
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)
CASES = tuple(p.name for p in sorted(pilot.CASES.glob('perf_*')))
VARIANTS = {
    'stores-only': ((1024,1,16384,2), {'RESULT_FALLTHROUGH':0,'STORE_HINTS':4}, {}),
    'results-only': ((1024,1,16384,2), {'POSTED_STORES':0,'STORE_HINTS':4}, {}),
    'combined': ((1024,1,16384,2), {'STORE_HINTS':4}, {}),
    'hints8': ((1024,1,16384,2), {'STORE_HINTS':8}, {}),
    'hints16': ((1024,1,16384,2), {'STORE_HINTS':16}, {}),
    'default': ((1024,1,4096,1), {}, {}),
    'big': ((2048,1,16384,2), {}, {}),
    'i1-d16': ((1024,1,16384,2), {}, {}),
    'i1-d4-2way': ((1024,1,4096,2), {}, {}),
    'i1-d8': ((1024,1,8192,2), {}, {}),
    'fe4-be2': ((2048,1,16384,2), {'FE_WIDTH':4}, {}),
    'fe2-be4': ((2048,1,16384,2), {'BE_WIDTH':4}, {}),
    'wide4': ((2048,1,16384,2), {'FE_WIDTH':4,'BE_WIDTH':4}, {}),
    'window': ((2048,1,16384,2), {'PHYS_REGS':96,'ROB_ENTRIES':64}, {}),
    'recovery8': ((2048,1,16384,2), {'RECOVERY_WIDTH':8}, {}),
    'lsq16': ((2048,1,16384,2), {}, {'LSQ_ENTRIES':16,'LSQ_INDEX_WIDTH':4,'LSQ_TAG_WIDTH':6}),
    'predictor': ((2048,1,16384,2), {}, {'predictor':True}),
}


def project(source, edits):
    if not edits:
        return
    path = source/'rtl/rv32_cpu_core.v'
    text = path.read_text()
    for key, value in edits.items():
        if key == 'predictor':
            continue
        import re
        text, n = re.subn(r'(parameter '+key+r' = )\d+', lambda m: m[1]+str(value), text)
        assert n == 1, key
    path.write_text(text)
    if edits.get('predictor'):
        path = source/'rtl/rv32_branch_predictor.v'
        text = path.read_text()
        replacements = [('[0:63]','[0:255]'),('[0:15]','[0:63]'),
            ('[3:0] query_btb_index','[5:0] query_btb_index'),
            ('[3:0] early_index','[5:0] early_index'),
            ('[5:0] update_bht_index','[7:0] update_bht_index'),
            ('[7:2]','[9:2]'),('[5:2]','[7:2]'),
            ('< 64;','< 256;'),('< 16;','< 64;'),
            ("update_bht_index = 6'd0", "update_bht_index = 8'd0"),
            ('update_lane_index*32 + 2 +: 6','update_lane_index*32 + 2 +: 8'),
            ('sequential_update_lane_index*32 + 2 +: 4','sequential_update_lane_index*32 + 2 +: 6')]
        for old,new in replacements:
            assert old in text,old
            text=text.replace(old,new)
        path.write_text(text)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--source',type=Path,default=ROOT)
    parser.add_argument('--variants',nargs='+',choices=VARIANTS,default=list(VARIANTS))
    args=parser.parse_args()
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    shutil.copyfile(HERE/'profile.h',out/'profile.h')
    shutil.copyfile(Path(__file__),out/'run.py')
    formal = sorted((args.source/'rtl').glob('*'))+[args.source/'verilog/filelist.f']
    guard={str(p):pilot.digest(p) for p in formal if p.is_file()}
    sources_hash={str(p):pilot.digest(p) for p in [out/'profile.h',out/'run.py',ROOT/'experiments/cache_20261014/run.py']}
    result={'completed':False,'passed':False,'rtl_sha256':guard,'runner_sha256':sources_hash,
            'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
            'latency':10,'results':[]}
    pilot.EXP=out
    harness=pilot.make_harness(out)
    sys.path.insert(0,str(pilot.FRAMEWORK/'scripts'))
    from build import read_sources
    from fakeram import with_ram_source
    try:
        for name in args.variants:
            geometry, params, edits=VARIANTS[name]
            dest=out/name;dest.mkdir()
            source=dest/'source'
            shutil.copytree(args.source/'rtl',source/'rtl')
            shutil.copytree(args.source/'verilog',source/'verilog')
            project(source,edits)
            params={'FE_WIDTH':2,'BE_WIDTH':2,'PHYS_REGS':64,'ROB_ENTRIES':32,'RECOVERY_WIDTH':4}|params|pilot.cache_parameters(geometry)
            flags='-std=c++17 -I'+str(out)+' '+ ' '.join('-DCONFIG_'+k+'='+str(v) for k,v in {
                'BE':params['BE_WIDTH'],'ROB':params['ROB_ENTRIES'],'LSQ':edits.get('LSQ_ENTRIES',8)}.items())
            files=with_ram_source(read_sources(source/'verilog/filelist.f'))
            command=['verilator','--cc','--exe','--build','--assert','--trace','--public-flat-rw',
                '-DRV32_TEST_WATCHDOG','-Wall','-Wno-fatal','--top-module','student_top',
                '--Mdir',str(dest/'obj'),'-o',str(dest/'sim'),'-j','2','-I'+str(source/'rtl'),'-CFLAGS',flags]
            command+=['-G'+k+'='+str(v) for k,v in params.items()]+list(map(str,files))+[str(harness)]
            print('BUILD',name,flush=True)
            pilot.execute(command,dest/'build.log',360)
            row={'variant':name,'parameters':params,'snapshot_edits':edits,'cases':[],
                 'source_sha256':{str(p):pilot.digest(p) for p in files+list((source/'rtl').glob('*.vh'))},
                 'sim_sha256':pilot.digest(dest/'sim')}
            result['results'].append(row)
            for case in CASES:
                item=pilot.run_case(dest/'sim',case)
                c=item['profile']['counts']
                assert sum(v for k,v in c.items() if k.startswith('store_stage_')) == c.get('partition_head_store_response',0)
                assert sum(v for k,v in c.items() if k.startswith('load_stage_')) == c.get('partition_head_load',0)
                assert sum(v for k,v in c.items() if k.startswith('retired_')) == c['retired']
                assert sum(v for k,v in c.items() if k.startswith('retire_width_')) == c['cycles']
                assert sum(v for k,v in c.items() if k.startswith('dispatch_width_')) == c['active_cycles']
                row['cases'].append(item)
                pilot.save(out/'results.json',result)
                print(name,case,item['cycles'],round(item['ipc'],6),flush=True)
            row['geomean']=math.exp(sum(math.log(c['ipc']) for c in row['cases'])/len(CASES))
        assert all(pilot.digest(Path(p))==sha for p,sha in guard.items())
        result.update(completed=True,passed=True,sources_unchanged=True)
    except Exception as error:
        result['error']=str(error)
        raise
    finally:
        pilot.save(out/'results.json',result)


if __name__=='__main__':
    main()
