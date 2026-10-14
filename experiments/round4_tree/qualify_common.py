#!/usr/bin/env python3
"""Qualify every common-flow mapping with identical electrical and hold goals."""
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import time
from stage import ROOT, EXP, OUT, CONFIGS, VARIANTS, stage, digest
from repair import repair, merge_and_analyze, refine_electrical, audit
from margin import close, TARGET_NS


def qualify(job):
    variant, config = job
    name = '{}x{}-p{}-r{}'.format(*config)
    base = OUT/'common-qualified'/variant/name
    base.mkdir(parents=True, exist_ok=True)
    native = OUT/'common-synth'/variant/name/'run.json'
    deadline = time.monotonic()+9000
    while True:
        try:
            raw = json.loads(native.read_text())
            break
        except (FileNotFoundError, json.JSONDecodeError):
            if time.monotonic() >= deadline:
                raise TimeoutError('common mapping did not complete')
            time.sleep(5)
    if not raw['passed'] or not raw['completed']:
        raise ValueError('common synthesis failed')
    original = Path(raw['report']).parent
    identity = {'source_design_sha256': digest(original/'design.json'), 'target_ns': TARGET_NS,
                'margin_code_sha256': digest(EXP/'margin.py'), 'code_sha256': digest(EXP/'qualify_common.py'),
                'repair_code_sha256': digest(ROOT/'experiments/round3_electrical/repair.py')}
    record = base/'run.json'
    if record.exists():
        cached = json.loads(record.read_text())
        if cached['passed'] and cached['identity'] == identity:
            return cached
        raise ValueError('common qualification provenance differs')
    print('START COMMON QUALIFY', variant, name, flush=True)
    audit(original, base/'raw-electrical')
    current = base/'electrical'
    repair(original, current)
    merge_and_analyze(original, current)
    electrical = refine_electrical(original, current)
    if not electrical['electrical_pass']:
        raise ValueError('common cap/slew closure failed')
    result = close(original, Path(electrical['final_directory']), base/'hold')
    result.update(variant=variant, config=name, original_directory=str(original), identity=identity)
    spec = importlib.util.spec_from_file_location('round3_paths', ROOT/'experiments/round3_electrical/paths.py')
    paths = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(paths)
    paths.audit(Path(result['final_directory']))
    record.write_text(json.dumps(result, indent=2)+'\n')
    print('DONE COMMON QUALIFY', variant, name, result['passed'], flush=True)
    return result


if __name__ == '__main__':
    stage()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(qualify, [(v, c) for c in CONFIGS[::-1] for v in ('baseline',)+VARIANTS]))
    (OUT/'common-qualification.json').write_text(json.dumps(results, indent=2)+'\n')
    stage()
