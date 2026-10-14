#!/usr/bin/env python3
"""Reproduce the four legacy-flow 20 ps references without running tree mapping."""
import concurrent.futures
import json
from stage import OUT, CONFIGS, stage
from qualify import qualify

if __name__ == '__main__':
    stage()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(qualify, [('baseline', c) for c in CONFIGS]))
    (OUT/'baseline-reference.json').write_text(json.dumps(rows, indent=2)+'\n')
    stage()
    print('Four legacy-flow 20 ps references qualified')
