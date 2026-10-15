#!/usr/bin/env python3
"""Measure branch restart and ready-to-issue latency on immutable snapshots."""
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('deep', ROOT/'experiments/deep_20261014/run.py')
deep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deep)
deep.HERE = HERE
geometry = (1024, 1, 16384, 2)
deep.VARIANTS = {'baseline': (geometry, {}, {'line_buffer': 0}),
                 'buffer1': (geometry, {}, {'line_buffer': 1}),
                 'buffer2': (geometry, {}, {'line_buffer': 2}),
                 'buffer4': (geometry, {}, {'line_buffer': 4})}
original_harness = deep.pilot.make_harness
original_case = deep.pilot.run_case
original_project = deep.project


def project(source, edits):
    original_project(source, {k: v for k, v in edits.items() if k != 'line_buffer'})
    if 'line_buffer' in edits:
        path = source/'rtl/rv32_fetch_pipeline.v'
        if edits['line_buffer'] == 0 and 'parameter FETCH_LINE_BUFFER_ENTRIES' not in path.read_text():
            return
        text, count = re.subn(r'(parameter FETCH_LINE_BUFFER_ENTRIES = )\d+',
                             lambda m: m[1]+str(edits['line_buffer']), path.read_text())
        assert count == 1
        path.write_text(text)


def make_harness(out):
    (out/'base_profile.h').write_bytes((ROOT/'experiments/deep_20261014/profile.h').read_bytes())
    return original_harness(out)


def run_case(sim, case):
    result = original_case(sim, case)
    matches = re.findall(r'^BRANCH (.*)$', (sim.parent/(case+'.stderr')).read_text(), re.M)
    assert len(matches) == 1
    result['branch'] = json.loads(matches[0])
    return result


deep.pilot.make_harness = make_harness
deep.pilot.run_case = run_case
deep.project = project

if __name__ == '__main__':
    deep.main()
