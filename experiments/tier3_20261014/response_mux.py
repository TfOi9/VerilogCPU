#!/usr/bin/env python3
"""Screen a response-owner mux change only in a frozen experiment copy."""
import importlib.util
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('tier3', HERE/'run.py')
tier3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tier3)
deep = tier3.deep
deep.VARIANTS = {'registered-owner': (tier3.geometry, {}, {})}


def project(source, edits):
    path = source/'rtl/student_top.v'
    text = path.read_text()
    for field in ('rob_tag', 'id'):
        old = 'assign core_d_response_'+field+' = mmio_response_valid ?'
        new = 'assign core_d_response_'+field+' = lsu_mmio_inflight ?'
        assert text.count(old) == 1
        text = text.replace(old, new)
    path.write_text(text)


deep.project = project
if __name__ == '__main__':
    out = Path(sys.argv[sys.argv.index('--out')+1]).resolve()
    paths = [Path(__file__), HERE/'run.py', HERE/'profile.h']
    hashes = {str(p): deep.pilot.digest(p) for p in paths}
    deep.main()
    assert all(deep.pilot.digest(Path(p)) == h for p, h in hashes.items())
    (out/'projection.json').write_text(json.dumps({'inputs': hashes,
        'change': 'Select response ROB tag and ID by registered MMIO ownership',
        'formal_rtl_modified': False, 'full_correctness_qualification': False}, indent=2)+'\n')
