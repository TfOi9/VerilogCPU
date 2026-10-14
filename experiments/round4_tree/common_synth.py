#!/usr/bin/env python3
"""Use one bounded fast-opt mapping flow for baseline and all tree candidates."""
import argparse
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import sys
from stage import ROOT, EXP, OUT, VARIANTS, CONFIGS, stage, digest
from repair import execute

FAST_SYNTH = '''hierarchy -check -top student_top
proc
flatten
opt_expr
opt_clean
check
opt -fast -nodffe -nosdff
fsm
opt -fast
wreduce
peepopt
opt_clean
alumacc
share
opt -fast
memory -nomap
opt_clean
opt -fast -full
memory_map
opt -fast -full
techmap
opt -fast
hierarchy -check
stat
check'''.splitlines()


def worker(variant, config):
    stage()
    name = '{}x{}-p{}-r{}'.format(*config)
    dest = OUT/'common-synth'/variant/name
    dest.mkdir(parents=True, exist_ok=True)
    filelist = ROOT/'build/round3-electrical/combined/filelist.f' if variant == 'baseline' else OUT/variant/'filelist.f'
    sys.path.insert(0, str(ROOT/'tools'))
    from run_synthesis import configured_sources, validate_report
    sys.path.insert(0, str(ROOT.parent/'RISC-V-CPU-2026/scripts'))
    from build import read_sources
    import synth as official
    _, originals = filelist, read_sources(filelist)
    configured, projected = configured_sources(originals, config, dest/'input')
    source_hashes = {str(p): digest(p) for p in originals+projected}
    for p in (dest/'input').glob('*.vh'):
        source_hashes[str(p)] = digest(p)
    identity = {'source_sha256': source_hashes, 'flow_sha256': digest(EXP/'common_synth.py')}
    record = dest/'run.json'
    if record.exists():
        old = json.loads(record.read_text())
        if old.get('passed') and old['identity'] == identity:
            return
        raise ValueError('common mapping provenance differs')
    def run_yosys(yosys, out, label, commands):
        rewritten = []
        for command in commands:
            if command.startswith('synth -top student_top '):
                rewritten.extend(FAST_SYNTH)
            else:
                rewritten.append(command)
        script = out/(label+'.ys')
        script.write_text('\n'.join(rewritten)+'\n')
        execute([yosys, '-Q', '-T', '-s', script], out/(label+'.log'), 2400 if label == 'synth' else 240)
    official.run_yosys = run_yosys
    sys.argv = ['synth.py', '--filelist', str(configured), '--out', str(dest), '--mode', 'opt',
                '--clock-period', '2.0', '--yosys', str(ROOT/'.deps/yosys/bin/yosys'),
                '--abc', str(ROOT/'.deps/yosys/bin/yosys-abc'), '--sta', str(ROOT/'.deps/opensta/bin/sta'),
                '--asap7-lib', str(ROOT/'.deps/asap7/lib')]
    official.main()
    report = json.loads((dest/'opt/report.json').read_text())
    validate_report(report, 'opt', 2.0)
    if any(digest(Path(p)) != h for p, h in source_hashes.items()):
        raise ValueError('common mapping sources changed')
    result = {'completed': True, 'passed': True, 'variant': variant, 'config': name, 'identity': identity,
              'flow': 'official synth expanded; opt calls use -fast; original dfflibmap, ABC, RAM and STA',
              'report': str(dest/'opt/report.json'),
              'native_tools': {str(p): digest(p) for p in (ROOT/'.deps/yosys/bin/yosys', ROOT/'.deps/yosys/bin/yosys-abc', ROOT/'.deps/opensta/bin/sta')}}
    record.write_text(json.dumps(result, indent=2)+'\n')


def run(job):
    variant, config = job
    name = '{}x{}-p{}-r{}'.format(*config)
    dest = OUT/'common-synth'/variant/name
    dest.mkdir(parents=True, exist_ok=True)
    execute([sys.executable, '-B', EXP/'common_synth.py', '--worker', variant, '--config', ','.join(map(str, config))],
            dest/'driver.log', 3000)
    r = json.loads((dest/'run.json').read_text())
    print('COMMON SYNTH', variant, name, json.loads(Path(r['report']).read_text())['timing']['estimated_fmax_mhz'], flush=True)
    return r


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--worker', choices=('baseline',)+VARIANTS)
    p.add_argument('--config')
    args = p.parse_args()
    if args.worker:
        worker(args.worker, tuple(map(int, args.config.split(','))))
    else:
        stage()
        configs = [tuple(map(int, args.config.split(',')))] if args.config else CONFIGS[::-1]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            result = list(pool.map(run, [(v, c) for c in configs for v in ('baseline',)+VARIANTS]))
        (OUT/'common-synthesis.json').write_text(json.dumps(result, indent=2)+'\n')
        stage()
