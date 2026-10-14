#!/usr/bin/env python3
"""Audit the complete regression, fresh official comparison and independent probes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT/'build/load-nonoverlap-20261014'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    spec = importlib.util.spec_from_file_location('load_qualification',
        ROOT/'experiments/load_path_20261014/qualify.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.OUT, module.HERE = OUT, HERE
    sys.argv = [str(Path(__file__)), '--stage', 'candidate', '--measurement', 'candidate']
    module.main()
    evidence = {}

    def read(path):
        evidence[str(path)] = digest(path)
        return json.loads(path.read_text())

    stages = {}
    snapshots = {}
    for name in ('baseline', 'candidate'):
        directory = OUT/name
        snapshot = read(directory/'snapshot.json')
        snapshots[name] = snapshot
        for path, sha in snapshot['source_sha256'].items():
            assert digest(Path(path)) == sha, path
        sim = read(directory/'sim-results.json')
        ppa = read(directory/'ppa-results.json')
        for record in (sim, ppa):
            assert record['completed'] and record['passed']
            assert record['snapshot_sha256'] == digest(directory/'snapshot.json')
        assert digest(directory/'official/sim') == sim['sim_sha256']
        assert len(sim['cases']) == 25
        for case in sim['cases']:
            log = directory/(case['name']+'.log')
            assert digest(log) == case['log_sha256']
            evidence[str(log)] = case['log_sha256']
        for path, sha in ppa['artifact_sha256'].items():
            assert digest(Path(path)) == sha, path
        for item in ppa['report']['inputs']+ppa['report']['libraries']:
            assert digest(Path(item['path'])) == item['sha256'], item['path']
        stages[name] = {'ipc_geomean': sim['ipc_geomean'],
            'area_um2': ppa['report']['area']['area_um2'],
            'fmax_mhz': ppa['report']['timing']['estimated_fmax_mhz'],
            'minimum_period_ns': ppa['report']['timing']['minimum_period_ns'],
            'cases': sim['cases'], 'report': str(directory/'ppa/opt/report.json')}
    assert snapshots['baseline']['configuration'] == snapshots['candidate']['configuration']
    framework = subprocess.check_output(['git', '-C', str(ROOT.parent/'RISC-V-CPU-2026'),
        'rev-parse', 'HEAD'], text=True).strip()
    assert framework == snapshots['baseline']['framework_revision'] == snapshots['candidate']['framework_revision']
    assert framework == subprocess.check_output(['git', '-C', str(ROOT.parent/'RISC-V-CPU-2026'),
        'rev-parse', 'origin/main'], text=True).strip()
    prior = read(ROOT/'experiments/load_path_20261014/load-results.json')
    for metric in ('ipc_geomean', 'area_um2', 'fmax_mhz', 'minimum_period_ns'):
        assert stages['baseline'][metric] == prior[metric], metric
    changed = []
    for path in (OUT/'baseline/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (ROOT/'build/load-path-20261014/load-precomputed/source/rtl'/path.name).read_bytes()
            candidate = OUT/'candidate/source/rtl'/path.name
            assert candidate.read_bytes() == (ROOT/'rtl'/path.name).read_bytes()
            if path.read_bytes() != candidate.read_bytes():
                changed.append(path.name)
    assert changed == ['rv32_load_store_queue.v']
    before, after = stages['baseline'], stages['candidate']
    assert after['ipc_geomean'] > before['ipc_geomean']
    assert after['area_um2'] <= 36000 and after['fmax_mhz'] >= 300
    assert [c['name'] for c in before['cases']] == [c['name'] for c in after['cases']]
    for a, b in zip(before['cases'], after['cases']):
        for field in ('image_sha256', 'expected_sha256', 'metrics_sha256', 'dynamic_instructions'):
            assert a.get(field) == b.get(field)
    targeted = read(OUT/'targeted-qualified/results.json')
    assert targeted['completed'] and targeted['passed'] and targeted['sources_unchanged']
    assert len(targeted['tests']) == 21 and all(t['passed'] for t in targeted['tests'])
    for path, sha in targeted['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    for test in targeted['tests']:
        for key in ('log', 'build_log'):
            assert digest(Path(test[key])) == test[key+'_sha256']
            evidence[test[key]] = test[key+'_sha256']
    positive = [t for t in targeted['tests'] if not t['expected_rejection']]
    negative = [t for t in targeted['tests'] if t['expected_rejection']]
    assert len(positive) == 18 and len(negative) == 3
    probes = read(OUT/'probes/results.json')
    assert probes['completed'] and probes['passed'] and len(probes['results']) == 6
    assert digest(ROOT/'tools/generate_core_vectors.py') == probes['reference_sha256']
    assert digest(HERE/'probes.py') == probes['runner_sha256']
    for row in probes['results']:
        assert row['passed']
        assert digest(OUT/row['stage']/'official/sim') == row['sim_sha256']
        for key in ('image', 'log'):
            assert digest(Path(row[key])) == row[key+'_sha256']
            evidence[row[key]] = row[key+'_sha256']
    qualification = read(HERE/'candidate-results.json')
    for item in qualification['preserved_inputs']:
        assert digest(Path(item['frozen'])) == item['sha256']
    for path, sha in qualification['evidence_sha256'].items():
        assert digest(Path(path)) == sha, path
    path_spec = importlib.util.spec_from_file_location('official_paths',
        ROOT/'experiments/tier3_20261014/summarize.py')
    path_module = importlib.util.module_from_spec(path_spec)
    path_spec.loader.exec_module(path_module)
    paths = {name: path_module.official_path(OUT/name/'ppa/opt') for name in stages}
    result = {'completed': True, 'passed': True, 'framework_revision': framework,
        'baseline_revision': 'f50d34e', 'configuration': snapshots['candidate']['configuration'],
        'stages': stages, 'change_percent': {k: (after[k]/before[k]-1)*100
            for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
        'estimated_throughput_change_percent':
            (after['ipc_geomean']*after['fmax_mhz']/(before['ipc_geomean']*before['fmax_mhz'])-1)*100,
        'ipc_gain_remaining_percent': (1.0985/after['ipc_geomean']-1)*100,
        'validation': qualification['validation'] | {
            'targeted_configurations': len(positive), 'targeted_checks': sum(t['checks'] for t in positive),
            'expected_baseline_rejections': len(negative), 'mixed_memory_probes': len(probes['results'])},
        'probes': probes['results'], 'critical_paths': paths, 'evidence_sha256': evidence,
        'audit_source_sha256': {str(p): digest(p) for p in [Path(__file__), HERE/'targeted.py',
            HERE/'probes.py', ROOT/'experiments/load_path_20261014/measure.py',
            ROOT/'experiments/load_path_20261014/qualify.py', HERE/'report.py',
            ROOT/'experiments/tier3_20261014/summarize.py',
            ROOT/'experiments/round3_electrical/hold.py']}}
    (HERE/'results-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS nonoverlap qualification', result['validation'], result['change_percent'])


if __name__ == '__main__':
    main()
