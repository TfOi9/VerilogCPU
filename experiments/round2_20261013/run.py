#!/usr/bin/env python3
"""Build fresh profiled simulators and validate all official cases and ISA kernels."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from setup import ROOT, EXP, OUT, VARIANTS, CONFIGS, digest, replace_once, verify
from micro import program

FRAMEWORK = ROOT.parent/'RISC-V-CPU-2026'
CASES = ROOT.parent/'RISC-V-CPU-2026-Testcases'

def execute(command, log, timeout):
    started = time.monotonic()
    command = list(map(str, command))
    with log.open('w') as output:
        p = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, cwd=ROOT, start_new_session=True)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            rc = -9
    result = {'command': command, 'returncode': rc, 'seconds': time.monotonic()-started,
              'timeout_seconds': timeout, 'log': str(log)}
    log.with_suffix('.command.json').write_text(json.dumps(result, indent=2)+'\n')
    if rc:
        raise RuntimeError('command failed: '+str(log))
    return result

def make_harness():
    text = (FRAMEWORK/'scripts/sim.cpp').read_text()
    for old, new in [('#include "Vstudent_top.h"', '#include "Vstudent_top.h"\n#include "profile.h"'),
                     ('Vstudent_top top{&context};', 'Vstudent_top top{&context};\n        Profile profile;'),
                     ('memory.step(top, latency);', 'profile.sample(top);\n            memory.step(top, latency);'),
                     ('top.final();', 'profile.report(top);\n        top.final();')]:
        text = replace_once(text, old, new)
    path = OUT/'profile_sim.cpp'
    path.write_text(text)
    return path

def build(variant, config):
    fe, be, phys, rob = config
    name = f'{fe}x{be}-p{phys}-r{rob}'
    target = OUT/variant/'sim'/name
    target.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(FRAMEWORK/'scripts'))
    from build import read_sources
    from fakeram import with_ram_source
    sources = with_ram_source(read_sources(OUT/variant/'filelist.f'))
    harness = make_harness()
    hashes = {str(p): digest(p) for p in sources+[harness, EXP/'profile.h']}
    sim = target/'sim'
    old = target/'sources.json'
    if sim.exists() and old.exists() and json.loads(old.read_text()) == hashes:
        return target, sim
    if sim.exists():
        archive = target/('sim-'+digest(sim)[:16])
        if not archive.exists():
            archive.write_bytes(sim.read_bytes())
            archive.chmod(0o755)
    command = ['verilator', '--cc', '--exe', '--build', '--trace', '--assert', '--public-flat-rw',
               '-DRV32_TEST_WATCHDOG', '-Wall', '-Wno-fatal', '--top-module', 'student_top',
               '--Mdir', target/'obj', '-o', sim, '-j', '2', '-I'+str(OUT/variant/'rtl'),
               '-CFLAGS', f'-std=c++17 -DVL_TIME_CONTEXT -DPROFILE_BE={be} -DPROFILE_ROB={rob} -I{EXP}',
               f'-GFE_WIDTH={fe}', f'-GBE_WIDTH={be}', f'-GPHYS_REGS={phys}', f'-GROB_ENTRIES={rob}', *sources, harness]
    execute(command, target/'build.log', 600)
    old.write_text(json.dumps(hashes, indent=2)+'\n')
    print('BUILT', variant, name, flush=True)
    return target, sim

def validate_profile(profile, cycles):
    c, h = profile['counts'], profile['histograms']
    checks = {}
    checks['cycles'] = c['cycles'] == cycles
    checks['partition'] = sum(v for k,v in c.items() if k.startswith('partition_')) == cycles
    checks['dispatch_partition'] = sum(v for k,v in c.items() if k.startswith('dispatch_block_primary_')) == c['dispatch_blocked_nonempty']
    for key in ('retirement_width', 'dispatch_width', 'issue_width', 'rob_occupancy', 'lsq_occupancy', 'int_rs_occupancy', 'fetch_occupancy', 'free_phys', 'axi_read_outstanding', 'axi_write_outstanding'):
        checks[key+'_samples'] = sum(h[key].values()) == cycles
    for key, count in (('retirement_width','retired'), ('dispatch_width','dispatched'), ('issue_width','issued')):
        checks[key+'_weighted'] = sum(int(k)*v for k,v in h[key].items()) == c[count]
    checks['retired_ops'] = sum(h['retired_op'].values()) == c['retired']
    checks['retired_pc'] = sum(h['retired_pc'].values()) == c['retired']
    checks['axi_r_balance'] = c.get('axi_reads',0)-c.get('axi_read_responses',0) == c['end_axi_read_outstanding']
    checks['axi_b_balance'] = c.get('axi_writes',0)-c.get('axi_write_responses',0) == c['end_axi_write_outstanding']
    requests = c.get('cache_store_requests',0)+c.get('cache_load_requests',0)
    checks['lsq_balance'] = requests-c.get('cache_responses',0) == c['end_lsq_request_pending']
    checks['response_samples'] = sum(h.get('cache_store_latency',{}).values())+sum(h.get('cache_load_latency',{}).values()) == c.get('cache_responses',0)
    return checks

def run_case(target, sim, name, image, expected, instructions=None):
    log = target/(name+'.log')
    result_path = target/(name+'.json')
    if result_path.exists():
        old = json.loads(result_path.read_text())
        if old.get('passed') and old.get('sim_sha256') == digest(sim) and old.get('image_sha256') == digest(image) and old.get('expected') == expected and old.get('dynamic_instructions') == instructions:
            print('REUSE', target.parent.parent.name, target.name, name, flush=True)
            return old
    result = execute([sim, image, expected, 30000000, 10], log, 600)
    text = log.read_text()
    match = re.search(r'PASS cycles=(\d+) result=', text)
    profile = re.search(r'^PROFILE (.*)$', text, re.M)
    if not match or not profile or re.search(r'(?m)^(ERROR|FAIL|%Error)\b', text):
        raise RuntimeError('missing successful result/profile: '+str(log))
    cycles = int(match[1])
    counters = json.loads(profile[1])
    checks = validate_profile(counters, cycles)
    if instructions is not None:
        checks['official_instruction_count'] = counters['counts']['retired'] == instructions-1
    row = dict(result, case=name, cycles=cycles, expected=expected, profile=counters,
               checks=checks, passed=all(checks.values()), sim_sha256=digest(sim), image_sha256=digest(image),
               dynamic_instructions=instructions, ipc=instructions/cycles if instructions else None)
    result_path.write_text(json.dumps(row, indent=2)+'\n')
    print(target.parent.parent.name, target.name, name, cycles, row['passed'], flush=True)
    if not row['passed']:
        raise RuntimeError('counter checks failed '+str({k:v for k,v in checks.items() if not v}))
    return row

def run_config(variant, config, cases):
    target, sim = build(variant, config)
    jobs = []
    for p in sorted(CASES.iterdir()):
        if p.name.startswith(('perf_', 'correctness_')) and (not cases or p.name in cases):
            metrics = p/'metrics.json'
            instructions = json.loads(metrics.read_text())['dynamic_instructions'] if metrics.exists() else None
            jobs.append((target, sim, p.name, p/'program.data', int((p/'expected.txt').read_text()), instructions))
    for kind in ('dependent-add','independent-add','hot-load','hot-store','rs-pressure','mdu-pressure'):
        if cases and kind not in cases:
            continue
        words, expected = program(kind)
        image = target/(kind+'.data')
        image.write_text('@00000000\n'+'\n'.join(' '.join(f'{v:02x}' for v in w.to_bytes(4,'little')) for w in words)+'\n')
        jobs.append((target, sim, kind, image, expected))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(lambda job: run_case(*job), jobs))
    (target/('results-selected.json' if cases else 'results.json')).write_text(json.dumps(rows, indent=2)+'\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--variants', nargs='+', default=list(VARIANTS))
    parser.add_argument('--config', help='FE,BE,PHYS,ROB')
    parser.add_argument('--cases', nargs='+')
    args = parser.parse_args()
    verify()
    configs = [tuple(map(int,args.config.split(',')))] if args.config else CONFIGS
    for config in configs:
        for variant in args.variants:
            run_config(variant, config, args.cases)
    verify()
