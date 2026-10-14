#!/usr/bin/env python3
"""Audit full regression, unchanged cycles and actual IPC times frequency gains."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT/'build/return-path-20261014'
VARIANTS = ('baseline', 'metadata-v2', 'metadata-wb-v2', 'rs-retain-v2', 'metadata-wb-rs-v2')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--measurement', required=True, choices=VARIANTS[1:])
    args = parser.parse_args()
    selected = args.measurement
    spec = importlib.util.spec_from_file_location('load_gates', ROOT/'experiments/load_path_20261014/qualify.py')
    gates = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gates)
    gates.OUT, gates.HERE = OUT, HERE
    sys.argv = [str(Path(__file__)), '--stage', 'final', '--measurement', selected]
    gates.main()
    evidence = {}

    def read(path):
        evidence[str(path)] = digest(path)
        return json.loads(path.read_text())

    path_spec = importlib.util.spec_from_file_location('official_paths', ROOT/'experiments/tier3_20261014/summarize.py')
    paths = importlib.util.module_from_spec(path_spec)
    path_spec.loader.exec_module(paths)
    rows = {}
    snapshots = {}
    for name in VARIANTS:
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
        assert len(sim['cases']) == 25
        assert digest(directory/'official/sim') == sim['sim_sha256']
        for case in sim['cases']:
            log = directory/(case['name']+'.log')
            assert digest(log) == case['log_sha256']
            evidence[str(log)] = case['log_sha256']
        for path, sha in ppa['artifact_sha256'].items():
            assert digest(Path(path)) == sha, path
        for item in ppa['report']['inputs']+ppa['report']['libraries']:
            assert digest(Path(item['path'])) == item['sha256']
        rows[name] = {'ipc_geomean': sim['ipc_geomean'], 'cases': sim['cases'],
            'area_um2': ppa['report']['area']['area_um2'],
            'fmax_mhz': ppa['report']['timing']['estimated_fmax_mhz'],
            'minimum_period_ns': ppa['report']['timing']['minimum_period_ns'],
            'critical_path': paths.official_path(directory/'ppa/opt')}
    framework = subprocess.check_output(['git', '-C', str(ROOT.parent/'RISC-V-CPU-2026'), 'rev-parse', 'HEAD'], text=True).strip()
    assert framework == subprocess.check_output(['git', '-C', str(ROOT.parent/'RISC-V-CPU-2026'), 'rev-parse', 'origin/main'], text=True).strip()
    for snapshot in snapshots.values():
        assert snapshot['framework_revision'] == framework
        assert snapshot['configuration'] == snapshots['baseline']['configuration']
    before, after = rows['baseline'], rows[selected]
    prior = read(ROOT/'experiments/load_nonoverlap_20261014/results-summary.json')['stages']['candidate']
    prior_load = read(ROOT/'experiments/load_path_20261014/load-results.json')
    for key in ('ipc_geomean', 'area_um2', 'fmax_mhz', 'minimum_period_ns'):
        assert before[key] == prior[key]
    for path in (OUT/'baseline/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (ROOT/'build/load-nonoverlap-20261014/candidate/source/rtl'/path.name).read_bytes()
    assert after['ipc_geomean']*after['fmax_mhz'] == max(
        r['ipc_geomean']*r['fmax_mhz'] for n, r in rows.items() if n != 'baseline')
    for name, row in rows.items():
        assert row['ipc_geomean'] == before['ipc_geomean']
        assert len(row['cases']) == len(before['cases'])
        for a, b in zip(before['cases'], row['cases']):
            for field in ('name', 'cycles', 'image_sha256', 'expected_sha256', 'metrics_sha256', 'dynamic_instructions'):
                assert a.get(field) == b.get(field), (name, field)
    assert after['fmax_mhz'] >= prior_load['fmax_mhz']
    assert after['ipc_geomean']*after['fmax_mhz'] > before['ipc_geomean']*before['fmax_mhz']
    assert after['ipc_geomean']*after['fmax_mhz'] > prior_load['ipc_geomean']*prior_load['fmax_mhz']
    qualified = read(HERE/'final-results.json')
    for item in qualified['preserved_inputs']:
        assert digest(Path(item['frozen'])) == item['sha256']
    for path, sha in qualified['evidence_sha256'].items():
        assert digest(Path(path)) == sha
    screen = read(OUT/'screen-v2/results.json')
    rs_screen = read(OUT/'rs-screen/results.json')
    audit = read(OUT/'path-audit.json')
    final_path = read(OUT/'selected-path/path-audit.json')
    archive = OUT/'final-int-rs-reuse-unit-archive'
    shutil.copytree(ROOT/'build/int-rs-reuse-unit', archive, dirs_exist_ok=True)
    reuse = read(archive/'results.json')
    assert len(reuse['tests']) == 9 and sum(t['checks'] for t in reuse['tests']) == 36864
    assert len(screen['tests']) == 22 and len(rs_screen['tests']) == 54
    for record in (screen, rs_screen, audit, final_path, reuse):
        assert record['passed'] and record['completed']
        for path, sha in record['source_sha256'].items():
            assert digest(Path(path)) == sha, path
        for test in record.get('tests', []):
            log = archive/Path(test['log']).name if record is reuse else Path(test['log'])
            assert test['passed'] and digest(log) == test['log_sha256']
            evidence[str(log)] = test['log_sha256']
    probes = read(OUT/'probes/results.json')
    assert probes['completed'] and probes['passed'] and len(probes['results']) == 6
    assert digest(ROOT/'tools/generate_core_vectors.py') == probes['reference_sha256']
    assert digest(HERE/'probes.py') == probes['runner_sha256']
    for a, b in zip(probes['results'][::2], probes['results'][1::2]):
        assert a['stage'] == 'baseline' and b['stage'] == selected
        for field in ('probe', 'cycles', 'instructions', 'expected', 'image_sha256'):
            assert a[field] == b[field], field
    for row in probes['results']:
        assert row['passed'] and digest(OUT/row['stage']/'official/sim') == row['sim_sha256']
        for key in ('image', 'log'):
            assert digest(Path(row[key])) == row[key+'_sha256']
            evidence[row[key]] = row[key+'_sha256']
    result = {'completed': True, 'passed': True, 'selected': selected, 'framework_revision': framework,
        'baseline_revision': '07e32b8', 'configuration': snapshots['baseline']['configuration'],
        'rows': rows, 'prior_load_version': {k: prior_load[k] for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
        'change_percent': {k: (after[k]/before[k]-1)*100 for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
        'throughput_change_percent': (after['ipc_geomean']*after['fmax_mhz']/(before['ipc_geomean']*before['fmax_mhz'])-1)*100,
        'throughput_vs_pre_nonoverlap_percent': (after['ipc_geomean']*after['fmax_mhz']/(prior_load['ipc_geomean']*prior_load['fmax_mhz'])-1)*100,
        'validation': qualified['validation'] | {'rs_reuse_configurations': 9, 'rs_reuse_checks': 36864,
            'isolated_protocol_tests': 22, 'rs_screen_tests': 54},
        'original_path_state': audit['paths'][0], 'final_path_state': final_path['paths'][0],
        'probes': probes['results'], 'evidence_sha256': evidence,
        'audit_source_sha256': {str(p): digest(p) for p in HERE.glob('*.py')}}
    (HERE/'results-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS final timing qualification', selected, result['change_percent'],
        'throughput', result['throughput_change_percent'])


if __name__ == '__main__':
    main()
