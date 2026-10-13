#!/usr/bin/env python3
"""Close hold on every electrically repaired configuration and retain provenance."""
import concurrent.futures
import json
from pathlib import Path
from repair import ROOT,OUT,digest,verify
from combined import CONFIGS,stage
from hold import close_hold

def run(job):
    variant,config=job
    name='{}x{}-p{}-r{}'.format(*config)
    parent=OUT/'optimized'/variant/name
    record=json.loads((parent/'run.json').read_text())
    if not record['completed'] or not record['electrical_pass']:
        raise ValueError('electrical closure incomplete')
    current=Path(record['final_directory'])
    original=OUT/'combined/synth'/name/'opt' if variant=='combined' else ROOT/'build/round2-20261013'/variant/'synth'/name/'opt'
    target=OUT/'closed'/variant/name
    identity={'source_design_sha256':digest(current/'design.json'),
              'hold_code_sha256':digest(Path(__file__).parent/'hold.py'),
              'repair_code_sha256':digest(Path(__file__).parent/'repair.py')}
    summary=target/'run.json'
    if summary.exists():
        old=json.loads(summary.read_text())
        if old.get('passed') and old['identity']==identity:
            return old
        raise ValueError('existing closed candidate inputs differ')
    print('START HOLD',variant,name,flush=True)
    result=close_hold(original,current,target)
    final=Path(result['final_directory'])
    cap=json.loads((final/'report.json').read_text())['electrical']['electrical_pass']
    result.update(variant=variant,config=name,identity=identity,passed=result['passed'] and cap)
    summary.write_text(json.dumps(result,indent=2)+'\n')
    print('DONE HOLD',variant,name,result['passed'],flush=True)
    return result

if __name__=='__main__':
    verify()
    stage()
    jobs=[(v,c) for c in CONFIGS for v in ('baseline','lsq-turnover','rs-ready-cut','combined')]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        result=list(pool.map(run,jobs))
    (OUT/'closed-summary.json').write_text(json.dumps(result,indent=2)+'\n')
    verify()
    stage()
    raise SystemExit(0 if all(r['passed'] for r in result) else 1)
