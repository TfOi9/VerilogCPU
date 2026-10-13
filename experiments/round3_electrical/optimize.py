#!/usr/bin/env python3
"""Apply the same proven electrical-repair algorithm to all four RTL variants."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import sys
from repair import ROOT,OUT,repair,merge_and_analyze,refine_electrical,verify,digest
from combined import stage,CONFIGS

def run(job):
    variant,config=job
    name='{}x{}-p{}-r{}'.format(*config)
    root=OUT/'combined/synth' if variant=='combined' else ROOT/'build/round2-20261013'/variant/'synth'
    mapped=root/name/'opt'
    if not (mapped/'report.json').exists():
        raise ValueError('source mapping has not completed: '+str(mapped))
    dest=OUT/'optimized'/variant/name
    identity={'design_sha256':digest(mapped/'design.json'),'repair_code_sha256':digest(Path(__file__).parent/'repair.py'),
              'fanout':8,'slew_ps':100,'driver':'INVx1_ASAP7_75t_R'}
    record=dest/'run.json'
    if record.exists():
        old=json.loads(record.read_text())
        if old['identity']==identity and old.get('completed'):
            print('REUSE',variant,name,old['electrical_pass'],flush=True)
            return old
        raise ValueError('existing repair inputs changed; use a fresh experiment namespace')
    print('START',variant,name,flush=True)
    repair(mapped,dest)
    merge_and_analyze(mapped,dest)
    closure=refine_electrical(mapped,dest)
    result={'variant':variant,'config':name,'identity':identity,**closure}
    record.write_text(json.dumps(result,indent=2)+'\n')
    print('DONE',variant,name,result['electrical_pass'],flush=True)
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--variants',nargs='+',default=['baseline','lsq-turnover','rs-ready-cut','combined'])
    args=parser.parse_args()
    verify()
    stage()
    jobs=[(v,c) for c in CONFIGS for v in args.variants]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        result=list(pool.map(run,jobs))
    verify()
    stage()
    summary=OUT/('optimization-'+('-'.join(args.variants))+'.json')
    summary.write_text(json.dumps(result,indent=2)+'\n')
    raise SystemExit(0 if all(r['electrical_pass'] for r in result) else 1)
