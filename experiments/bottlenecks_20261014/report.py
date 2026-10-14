#!/usr/bin/env python3
"""Audit frozen diagnostic runs and publish their machine-readable evidence."""
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import tempfile

import run

ROOT = run.ROOT
HERE = run.HERE
RAW = ROOT / 'build/bottlenecks-20261014'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_hashes(hashes):
    for name, expected in hashes.items():
        assert digest(Path(name)) == expected, name


def mean(values):
    return math.exp(sum(math.log(v) for v in values) / len(values))


def check_profile(item):
    p = item['profile']
    c = p['counts']
    assert sum(v for k, v in c.items() if k.startswith('partition_')) == c['cycles'] == item['cycles']
    assert sum(v for k, v in c.items() if k.startswith('retired_')) == c['retired']
    assert sum(v for k, v in c.items() if k.startswith('store_stage_')) == c.get('partition_head_store_response', 0)
    assert sum(v for k, v in c.items() if k.startswith('load_stage_')) == c.get('partition_head_load', 0)
    assert sum(v for k, v in c.items() if k.startswith('retire_width_')) == c['cycles']
    for prefix in ('dispatch_width_', 'issue_width_', 'issue_grants_', 'completion_width_'):
        assert sum(v for k, v in c.items() if k.startswith(prefix)) == c['active_cycles']
    assert sum(p['recovery_lengths'].values()) == c.get('recovery_events', 0)
    assert sum(int(k) * v for k, v in p['recovery_lengths'].items()) == c.get('partition_recovery', 0)
    assert sum(int(k) * v for k, v in p['rollback_depths'].items()) == c.get('rollback_entries', 0)
    assert sum(p['request_gaps'].values()) == c.get('store_requests', 0) + c.get('load_requests', 0) - 1


def main():
    previous_path = ROOT / 'experiments/optimization_20261014/results-summary.json'
    previous = json.loads(previous_path.read_text())
    verify_hashes({str(ROOT / 'rtl' / name): value for name, value in previous['rtl_sha256'].items()})
    variants = {}
    manifests = []
    formal_hashes = None
    for group in ('profile-v2', 'sensitivity', 'width-isolation'):
        folder = RAW / group
        result = json.loads((folder / 'results.json').read_text())
        assert result['completed'] and result['passed'] and result['sources_unchanged']
        assert result['latency'] == 10
        verify_hashes(result['rtl_sha256'])
        verify_hashes(result['runner_sha256'])
        if formal_hashes is None:
            formal_hashes = result['rtl_sha256']
        assert result['rtl_sha256'] == formal_hashes
        assert (folder / 'profile.h').read_bytes() == (HERE / 'profile.h').read_bytes()
        with tempfile.TemporaryDirectory() as tmp:
            recreated = run.pilot.make_harness(Path(tmp))
            assert recreated.read_bytes() == (folder / 'profile_sim.cpp').read_bytes()
        manifests.append({'raw_result': str(folder / 'results.json'),
                          'raw_sha256': digest(folder / 'results.json'),
                          'head_at_run': result['head'],
                          'runner_sha256': result['runner_sha256'],
                          'harness_sha256': digest(folder / 'profile_sim.cpp')})
        for row in result['results']:
            name = row['variant']
            assert name not in variants
            verify_hashes(row['source_sha256'])
            dest = folder / name
            assert digest(dest / 'sim') == row['sim_sha256']
            with tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp)
                shutil.copytree(ROOT / 'rtl', source / 'rtl')
                run.project(source, row['snapshot_edits'])
                for path in (source / 'rtl').iterdir():
                    if path.is_file():
                        assert path.read_bytes() == (dest / 'source/rtl' / path.name).read_bytes(), name
            assert (dest / 'source/verilog/filelist.f').read_bytes() == (ROOT / 'verilog/filelist.f').read_bytes()
            assert [c['case'] for c in row['cases']] == list(run.CASES)
            for case in row['cases']:
                assert case['passed']
                name_case = case['case']
                for ext in ('stdout', 'stderr'):
                    assert digest(dest / (name_case + '.' + ext)) == case[ext + '_sha256']
                stderr = (dest / (name_case + '.stderr')).read_text()
                assert json.loads(re.search(r'^PROFILE (.*)$', stderr, re.M)[1]) == case['profile']
                metrics = json.loads((run.pilot.CASES / name_case / 'metrics.json').read_text())
                assert case['dynamic_instructions'] == metrics['dynamic_instructions']
                assert case['profile']['counts']['retired'] == case['dynamic_instructions'] - 1
                assert case['ipc'] == case['dynamic_instructions'] / case['cycles']
                check_profile(case)
            assert math.isclose(row['geomean'], mean([c['ipc'] for c in row['cases']]))
            variants[name] = copy.deepcopy(row) | {'raw_directory': str(dest)}
    assert len(variants) == 12
    reproduced = 0
    for old, new in zip(previous['performance'], ('default', 'big')):
        assert [c['case'] for c in old['cases']] == list(run.CASES)
        for before, current in zip(old['cases'], variants[new]['cases']):
            assert before['after_cycles'] == current['cycles']
            old_counts = before['after_profile']['counts']
            assert all(current['profile']['counts'].get(k, 0) == v for k, v in old_counts.items())
            reproduced += 1
    probes = json.loads((RAW / 'probes/results.json').read_text())
    assert probes['completed'] and probes['passed']
    assert probes['sim_sha256'] == variants['big']['sim_sha256']
    for probe in probes['results']:
        assert digest(RAW / 'probes' / (probe['probe'] + '.data')) == probe['image_sha256']
        assert probe['profile']['counts']['retired'] == probe['instructions'] - 1
        check_profile(probe)
    base = variants['big']['geomean']
    for row in variants.values():
        row['speedup_over_big'] = row['geomean'] / base
    counterfactual = {}
    for names in (('head_store_response',), ('recovery',), ('head_load',),
                  ('head_store_response', 'head_load'), ('head_store_response', 'recovery')):
        values = []
        for case in variants['big']['cases']:
            c = case['profile']['counts']
            remaining = case['cycles'] - sum(c.get('partition_' + key, 0) for key in names)
            values.append(case['dynamic_instructions'] / remaining)
        counterfactual['+'.join(names)] = mean(values)
    inputs = [run.pilot.FRAMEWORK / 'scripts' / f for f in ('sim.cpp', 'fakeram.py', 'build.py')]
    inputs += [run.pilot.CASES / case / f for case in run.CASES
               for f in ('program.data', 'metrics.json', 'expected.txt')]
    summary = {
        'completed': True, 'passed': True, 'formal_rtl_unchanged': True,
        'scope': '72 official performance runs and 5 reference-checked probes; no new full correctness matrix or synthesis',
        'case_timeout_seconds': 30, 'build_timeout_seconds': 360,
        'baseline_runs_reproduced': reproduced, 'latency': 10,
        'target_ipc': 1.0985, 'target_speedup_over_big': 1.0985 / base,
        'rtl_sha256': formal_hashes, 'raw_manifests': manifests,
        'inputs_sha256_at_report_time': {str(p): digest(p) for p in inputs},
        'input_hash_scope': 'Recorded at report time; original run guards cover RTL, not all external inputs. Frozen harness matches current official harness plus instrumentation.',
        'previous_summary_sha256': digest(previous_path),
        'ppa_reused_from_previous_round': previous['ppa'][1:],
        'variants': variants, 'probes': probes,
        'fixed_cycle_deletion_geomeans': counterfactual,
        'counterfactual_scope': 'Bookkeeping only; not achievable predictions or architectural upper bounds. Other cycles are artificially held fixed.',
    }
    (HERE / 'results-summary.json').write_text(json.dumps(summary, indent=2, allow_nan=False) + '\n')
    print('PASS: 12 configurations, 72 performance runs, 5 probes, 12 reproduced baseline runs; hashes and accounting verified')


if __name__ == '__main__':
    main()
