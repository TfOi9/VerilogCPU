#!/usr/bin/env python3
"""Run full unit and parameter suites plus response-boundary LSQ tests."""
import argparse
import json
import re
import sys
from setup import ROOT, EXP, OUT, VARIANTS, replace_once, verify
from run import execute

def directed(variant):
    target = OUT/variant/'directed'
    target.mkdir(parents=True, exist_ok=True)
    text = (ROOT/'tb/rv32_load_store_queue_tb.v').read_text()
    text = replace_once(text, '        $display("PASS rv32_load_store_queue_tb width=%0d checks=%0d",',
        (EXP/'lsq_turnover_cases.vh').read_text()+'\n        $display("PASS rv32_load_store_queue_tb width=%0d checks=%0d",')
    tb = target/'rv32_load_store_queue_tb.v'
    tb.write_text(text)
    results = []
    for width in (1,2,4):
        binary = target/f'lsq-{width}.vvp'
        command = ['iverilog','-g2005','-I',str(OUT/variant/'rtl'),'-s','rv32_load_store_queue_tb',
                   '-P',f'rv32_load_store_queue_tb.BE_WIDTH={width}','-o',binary,
                   OUT/variant/'rtl/rv32_load_store_queue.v',tb]
        if variant == 'lsq-turnover':
            command.insert(1,'-DEXPECT_TURNOVER')
        execute(command, target/f'compile-{width}.log',30)
        result = execute(['vvp','-N',binary],target/f'run-{width}.log',30)
        text = (target/f'run-{width}.log').read_text()
        result['passed'] = bool(re.search(r'^PASS ',text,re.M)) and not re.search(r'^(ERROR|FAIL)\b',text,re.M)
        result['be_width'] = width
        results.append(result)
        print(variant,'LSQ response boundary',width,result['passed'],flush=True)
    (target/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    if not all(r['passed'] for r in results):
        raise RuntimeError('directed LSQ tests failed')

def unit(variant):
    target = OUT/variant
    result = execute(['make','--no-print-directory','-f',target/'Makefile.unit','unit'],target/'unit.log',900)
    text = (target/'unit.log').read_text()
    result.update(variant=variant, passed=not re.search(r'^(ERROR|FAIL|%Error)\b',text,re.M), pass_lines=len(re.findall(r'^PASS',text,re.M)))
    (target/'unit.json').write_text(json.dumps(result,indent=2)+'\n')
    if not result['passed']:
        raise RuntimeError('unit reported a failure despite process exit status zero')

def matrix(variant, jobs=4, lint_jobs=6):
    target = OUT/variant
    execute([sys.executable,'-B',ROOT/'tools/run_parameter_matrix.py','--filelist',target/'filelist.f',
             '--build-root',target/'matrix','--report',target/'matrix.json','--jobs',str(jobs),'--lint-jobs',str(lint_jobs)],target/'matrix-driver.log',3600)
    if not json.loads((target/'matrix.json').read_text())['passed']:
        raise RuntimeError('matrix validation failed')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase',choices=['unit','matrix','directed','all'],default='all')
    parser.add_argument('--variants',nargs='+',default=list(VARIANTS))
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--lint-jobs',type=int,default=6)
    args = parser.parse_args()
    verify()
    for v in args.variants:
        for name, function in [('unit',unit),('directed',directed),('matrix',matrix)]:
            if args.phase in (name,'all'):
                if name == 'matrix':
                    function(v,args.jobs,args.lint_jobs)
                else:
                    function(v)
    verify()
