#!/usr/bin/env python3
"""Apply identical mapping repair and positive hold targets to every candidate."""
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import time
from stage import ROOT, EXP, OUT, CONFIGS, VARIANTS, stage, digest
from repair import repair, merge_and_analyze, refine_electrical
from margin import close, TARGET_NS


def qualify(job):
    variant, config = job
    name = '{}x{}-p{}-r{}'.format(*config)
    base = OUT/'qualified'/variant/name
    base.mkdir(parents=True, exist_ok=True)
    if variant == 'baseline':
        original = ROOT/'build/round3-electrical/combined/synth'/name/'opt'
        old = json.loads((ROOT/'build/round3-electrical/optimized/combined'/name/'run.json').read_text())
        current = Path(old['final_directory'])
    else:
        original = OUT/variant/'synth'/name/'opt'
        deadline = time.monotonic()+6000
        while not (OUT/variant/'synth'/(name+'.json')).exists():
            if time.monotonic() >= deadline:
                raise TimeoutError('native mapping did not finish')
            time.sleep(5)
        r = json.loads((OUT/variant/'synth'/(name+'.json')).read_text())
        if not r['completed'] or not r['passed'] or not r['sources_unchanged']:
            raise ValueError('source mapping failed')
        current = base/'electrical'
    identity = {'design_sha256': digest(original/'design.json'), 'target_hold_ns': TARGET_NS,
                'margin_code_sha256': digest(EXP/'margin.py'), 'qualify_code_sha256': digest(EXP/'qualify.py'),
                'repair_code_sha256': digest(ROOT/'experiments/round3_electrical/repair.py')}
    record = base/'run.json'
    if record.exists():
        r = json.loads(record.read_text())
        if r['passed'] and r['identity'] == identity:
            return r
        raise ValueError('qualification cache differs')
    print('START QUALIFY', variant, name, flush=True)
    if variant != 'baseline':
        repair(original, current)
        merge_and_analyze(original, current)
        electrical = refine_electrical(original, current)
        if not electrical['electrical_pass']:
            raise ValueError('cap/slew closure failed')
        current = Path(electrical['final_directory'])
    result = close(original, current, base/'hold')
    result.update(variant=variant, config=name, original_directory=str(original), identity=identity)
    spec = importlib.util.spec_from_file_location('round3_paths', ROOT/'experiments/round3_electrical/paths.py')
    paths = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(paths)
    paths.audit(Path(result['final_directory']))
    record.write_text(json.dumps(result, indent=2)+'\n')
    print('DONE QUALIFY', variant, name, result['passed'], flush=True)
    return result


if __name__ == '__main__':
    stage()
    jobs = [('baseline', c) for c in CONFIGS[::-1]]
    jobs += [(v, c) for c in CONFIGS[::-1] for v in VARIANTS]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(qualify, jobs))
    (OUT/'qualification.json').write_text(json.dumps(results, indent=2)+'\n')
    stage()
