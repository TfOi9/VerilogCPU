#!/usr/bin/env python3
"""Measure dependency and throughput probes using an architectural reference."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from generate_core_vectors import immediate,register,store,branch,execute


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sim',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    args=p.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    rows=[]
    for kind in ['alu-chain','alu-four-chains','load-chain','load-independent','hot-store']:
        words=[0x000100b7,immediate(2,0,200),store(1,1,0)]
        for rd in range(10,14): words.append(immediate(rd,0,0))
        loop=len(words)*4
        for i in range(64):
            if kind=='alu-chain': words.append(immediate(10,10,1))
            elif kind=='alu-four-chains': words.append(immediate(10+i%4,10+i%4,1))
            elif kind=='load-chain': words.append(immediate(1,1,0,2,0x03))
            elif kind=='load-independent': words.append(immediate(10+i%4,1,0,2,0x03))
            else: words.append(store(1,1,0))
        words.append(immediate(2,2,-1));words.append(branch(2,0,loop-len(words)*4,1))
        if kind=='alu-four-chains':
            words.extend(register(10,10,i) for i in [11,12,13])
        if kind=='load-chain': words.append(immediate(10,1,0))
        words.extend([0x80000fb7,store(10,31,0)])
        trace,expected=execute(words)
        image=args.out/(kind+'.data')
        image.write_text('@00000000\n'+'\n'.join(' '.join(f'{b:02x}' for b in w.to_bytes(4,'little')) for w in words)+'\n')
        command=['timeout','-k','5','30',str(args.sim.resolve()),str(image.resolve()),str(expected),'1000000','10']
        run=subprocess.run(command,text=True,capture_output=True)
        (args.out/(kind+'.log')).write_text(run.stdout+run.stderr)
        match=re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*',run.stdout)
        assert run.returncode==0 and match and int(match[2])==int(match[3])==expected
        profile=json.loads(re.search(r'^PROFILE (.*)$',run.stderr,re.M)[1])
        assert profile['counts']['retired']==len(trace)-1
        row={'probe':kind,'cycles':int(match[1]),'instructions':len(trace),'expected':expected,
             'ipc':len(trace)/int(match[1]),'profile':profile,'command':command,
             'image_sha256':hashlib.sha256(image.read_bytes()).hexdigest()}
        rows.append(row);print(kind,row['cycles'],row['ipc'],flush=True)
    result={'completed':True,'passed':True,'sim_sha256':hashlib.sha256(args.sim.read_bytes()).hexdigest(),
            'results':rows}
    (args.out/'results.json').write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__': main()
