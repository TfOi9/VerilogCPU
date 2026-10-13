#!/usr/bin/env python3
"""Build and regress the isolated LSQ-turnover plus RS-ready-cut candidate."""
import argparse
import json
from pathlib import Path
import shutil
import sys

from repair import ROOT,OUT,digest,verify

sys.path.insert(0,str(ROOT/'experiments/round2_20261013'))
import run as bench
from setup import CONFIGS

OLD=ROOT/'build/round2-20261013'

def stage():
    verify()
    dest=OUT/'combined'
    marker=dest/'manifest.json'
    if marker.exists():
        hashes=json.loads(marker.read_text())['rtl_sha256']
        if any(digest(Path(p))!=sha for p,sha in hashes.items()):
            raise ValueError('combined snapshot changed')
        return dest
    dest.mkdir(parents=True,exist_ok=True)
    old=OLD/'rs-ready-cut'
    shutil.copytree(old/'rtl',dest/'rtl')
    shutil.copytree(old/'tb',dest/'tb')
    shutil.copyfile(OLD/'lsq-turnover/rtl/rv32_load_store_queue.v',dest/'rtl/rv32_load_store_queue.v')
    shutil.copyfile(old/'generate_int_rs_vectors.py',dest/'generate_int_rs_vectors.py')
    (dest/'unit').mkdir()
    (dest/'Makefile.unit').write_text((old/'Makefile.unit').read_text().replace(str(old),str(dest)))
    names=[Path(p).name for p in (OLD/'baseline/filelist.f').read_text().splitlines()]
    (dest/'filelist.f').write_text('\n'.join(str(dest/'rtl'/n) for n in names)+'\n')
    (dest/'manifest.json').write_text(json.dumps({'parent_rtl':'4fa767cf09cdeebd1ced43973d53490acb6008a5',
        'rtl_sha256':{str(p):digest(p) for p in sorted((dest/'rtl').iterdir())}},indent=2)+'\n')
    return dest

def regression():
    dest=stage()
    bench.execute(['make','--no-print-directory','-f',dest/'Makefile.unit','unit'],dest/'unit.log',900)
    import re
    text=(dest/'unit.log').read_text()
    if re.search(r'(?m)^(FAIL|ERROR|%Error)\b',text):
        raise ValueError('unit reported a failure')
    (dest/'unit.json').write_text(json.dumps({'passed':True,'pass_lines':len(re.findall(r'(?m)^PASS',text))},indent=2)+'\n')
    direct=dest/'directed'
    direct.mkdir(exist_ok=True)
    tb=direct/'rv32_load_store_queue_tb.v'
    shutil.copyfile(OLD/'lsq-turnover/directed/rv32_load_store_queue_tb.v',tb)
    for width in (1,2,4):
        binary=direct/f'lsq-{width}.vvp'
        bench.execute(['iverilog','-g2005','-DEXPECT_TURNOVER','-I',dest/'rtl',
            '-s','rv32_load_store_queue_tb','-P',f'rv32_load_store_queue_tb.BE_WIDTH={width}',
            '-o',binary,dest/'rtl/rv32_load_store_queue.v',tb],direct/f'compile-{width}.log',30)
        bench.execute(['vvp','-N',binary],direct/f'run-{width}.log',30)
        text=(direct/f'run-{width}.log').read_text()
        if not re.search(r'(?m)^PASS',text) or re.search(r'(?m)^(FAIL|ERROR)\b',text):
            raise ValueError('combined LSQ boundary test failed')
    bench.execute([sys.executable,'-B',ROOT/'tools/run_parameter_matrix.py',
        '--filelist',dest/'filelist.f','--build-root',dest/'matrix','--report',dest/'matrix.json',
        '--jobs','2','--lint-jobs','4'],dest/'matrix-driver.log',3600)
    if not json.loads((dest/'matrix.json').read_text())['passed']:
        raise ValueError('combined parameter matrix failed')

def simulation():
    stage()
    bench.OUT=OUT
    for config in CONFIGS:
        bench.run_config('combined',config,None)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--phase',choices=('stage','regression','simulation'),required=True)
    args=parser.parse_args()
    if args.phase=='stage':
        print(stage())
    elif args.phase=='regression':
        regression()
    else:
        simulation()
    stage()
