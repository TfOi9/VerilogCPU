#!/usr/bin/env python3
"""Audit the first branch optimization against frozen simulation and official PPA."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    out = args.root.resolve()
    evidence = {}

    def read(path):
        path = Path(path)
        evidence[str(path)] = digest(path)
        return json.loads(path.read_text())

    def snapshot(directory):
        data = read(directory/'snapshot.json')
        for path, sha in data['source_sha256'].items():
            assert digest(Path(path)) == sha, path
        return data

    def simulation(directory):
        data = read(directory/'sim-results.json')
        assert data['completed'] and data['passed'] and len(data['cases']) == 25
        official = {p.name for p in (ROOT.parent/'RISC-V-CPU-2026-Testcases').iterdir()
                    if (p/'program.data').is_file()}
        assert {c['name'] for c in data['cases']} == official and len(official) == 25
        assert data['snapshot_sha256'] == digest(directory/'snapshot.json')
        assert data['sim_sha256'] == digest(directory/'official/sim')
        for case in data['cases']:
            log = directory/(case['name']+'.log')
            assert digest(log) == case['log_sha256']
            evidence[str(log)] = digest(log)
            for name, field in [('program.data', 'image_sha256'), ('expected.txt', 'expected_sha256')]:
                path = ROOT.parent/'RISC-V-CPU-2026-Testcases'/case['name']/name
                assert digest(path) == case[field], path
            if case['name'].startswith('perf_'):
                path = ROOT.parent/'RISC-V-CPU-2026-Testcases'/case['name']/'metrics.json'
                assert digest(path) == case['metrics_sha256']
                assert json.loads(path.read_text())['dynamic_instructions'] == case['dynamic_instructions']
                assert case['ipc'] == case['dynamic_instructions']/case['cycles']
        performance = [c['ipc'] for c in data['cases'] if c['name'].startswith('perf_')]
        assert len(performance) == 6
        assert math.exp(sum(map(math.log, performance))/6) == data['ipc_geomean']
        return data

    def ppa(directory):
        data = read(directory/'ppa-results.json')
        assert data['completed'] and data['passed']
        assert data['snapshot_sha256'] == digest(directory/'snapshot.json')
        for path, sha in data['artifact_sha256'].items():
            assert digest(Path(path)) == sha, path
        report = data['report']
        for item in report['inputs']+report['libraries']:
            assert digest(Path(item['path'])) == item['sha256']
        assert report['abc_constraints'] == {'driving_cell': 'INVx1_ASAP7_75t_R', 'output_load_ff': 5.0}
        return {'area_um2': report['area']['area_um2'],
                'fmax_mhz': report['timing']['estimated_fmax_mhz'],
                'minimum_period_ns': report['timing']['minimum_period_ns']}

    baseline_snapshot = snapshot(out/'baseline')
    selected_snapshot = snapshot(out/'selected')
    assert baseline_snapshot['configuration'] == selected_snapshot['configuration']
    assert baseline_snapshot['framework_revision'] == selected_snapshot['framework_revision']
    assert selected_snapshot['framework_revision'] == '302f0cf3cccdaa5de084a2120e0d950c663e4cf5'
    baseline = simulation(out/'baseline')
    selected = simulation(out/'selected')
    for a, b in zip(baseline['cases'], selected['cases']):
        for field in ('name', 'image_sha256', 'expected_sha256', 'metrics_sha256', 'dynamic_instructions'):
            assert a.get(field) == b.get(field), (a['name'], field)
    prior_dir = ROOT/'build/return-path-20261014/metadata-wb-v2'
    snapshot(prior_dir)
    for path in (out/'baseline/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (prior_dir/'source/rtl'/path.name).read_bytes(), path
    prior = simulation(prior_dir)
    assert baseline['ipc_geomean'] == prior['ipc_geomean']
    assert [(c['name'], c['cycles']) for c in baseline['cases']] == [(c['name'], c['cycles']) for c in prior['cases']]
    before = ppa(prior_dir) | {'ipc_geomean': baseline['ipc_geomean']}
    after = ppa(out/'selected') | {'ipc_geomean': selected['ipc_geomean']}
    for path in (out/'selected/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (ROOT/'rtl'/path.name).read_bytes(), path
    assert after['area_um2'] <= 36000 and after['fmax_mhz'] >= 300
    assert after['ipc_geomean'] > before['ipc_geomean']
    assert after['ipc_geomean']*after['fmax_mhz'] > before['ipc_geomean']*before['fmax_mhz']

    profile = read(out/'screen-v3/results.json')
    assert profile['completed'] and profile['passed'] and profile['sources_unchanged']
    for path, sha in profile['runner_sha256'].items():
        assert digest(Path(path)) == sha, path
    assert (out/'screen-v3/profile.h').read_bytes() == (HERE/'profile.h').read_bytes()
    assert (out/'screen-v3/base_profile.h').read_bytes() == (ROOT/'experiments/deep_20261014/profile.h').read_bytes()
    candidates = {v['variant']: v for v in profile['results']}
    assert candidates['baseline']['geomean'] == before['ipc_geomean']
    assert candidates['buffer4']['geomean'] == after['ipc_geomean']
    branch = {}
    for name in ('baseline', 'buffer2', 'buffer4'):
        candidate = candidates[name]
        for path, sha in candidate['source_sha256'].items():
            assert digest(Path(path)) == sha
        branch[name] = []
        for case in candidate['cases']:
            counts = case['profile']['counts']
            finished = sum(case['branch']['redirect_to_target_retire'].values())
            pending = counts['restart_events']-counts.get('restart_superseded', 0)-finished
            assert pending in (0, 1), (name, case['case'], pending)
            for suffix in ('stdout', 'stderr'):
                log = out/'screen-v3'/name/(case['case']+'.'+suffix)
                assert digest(log) == case[suffix+'_sha256']
                evidence[str(log)] = digest(log)
            branch[name].append({'case': case['case'], 'cycles': case['cycles'],
                'histograms': case['branch'], 'restart_events': case['profile']['counts']['restart_events'],
                'superseded': case['profile']['counts'].get('restart_superseded', 0)})
        if name == 'buffer4':
            for path in (out/'selected/source/rtl').glob('*'):
                if path.is_file():
                    assert path.read_bytes() == (out/'screen-v3/buffer4/source/rtl'/path.name).read_bytes(), path

    matrix = read(out/'matrix.json')
    assert matrix['completed'] and matrix['passed'] and matrix['sources_unchanged']
    assert len(matrix['matrix']) == 81 and len(matrix['representatives']) == 9
    for path, sha in matrix['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    for row in matrix['checks']:
        assert row['passed'] and row['returncode'] == 0, row
        path = Path(row['log'])
        evidence[str(path)] = digest(path)
    static_checks = sum(c['stage'] in ('iverilog-2005', 'parameter-startup', 'verilator', 'yosys')
                        for c in matrix['checks'])
    retirement_traces = sum(c['stage'].startswith('retirement-') for c in matrix['checks'])
    program_runs = sum(len(f['results']) for f in matrix['functional'])
    assert static_checks == 324 and retirement_traces == 27 and program_runs == 243
    gates = read(out/'gates/results.json')
    assert gates['completed'] and gates['passed'] and len(gates['tests']) == 4
    for row in gates['tests']:
        assert row['exit_code'] == 0 and digest(Path(row['log'])) == row['log_sha256']
        evidence[row['log']] = row['log_sha256']
    hum = read(out/'gates/hum/results.json')
    owner = read(out/'gates/response-owner/results.json')
    assert hum['completed'] and hum['passed'] and hum['sources_unchanged'] and len(hum['tests']) == 28
    assert owner['passed'] and len(owner['tests']) == 3
    owner_checks = sum(t['checks'] for t in owner['tests'])
    assert owner_checks == 7168
    for record in (hum, owner):
        for path, sha in record['source_sha256'].items():
            assert digest(Path(path)) == sha, path
    for path, sha in gates['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    unit = (out/'gates/unit.log').read_text()
    checks = re.findall(r'^PASS fetch_line_buffer FE=\d+ BE=\d+ entries=\d+ checks=(\d+)$', unit, re.M)
    assert len(checks) == 27
    assert 'PASS fetch line buffer disabled negative control' in unit
    assert 'PASS fetch line buffer rejected invalid entries' in unit
    probes = read(out/'probes/results.json')
    assert probes['completed'] and probes['passed'] and len(probes['results']) == 4
    assert probes['reference_sha256'] == digest(ROOT/'tools/generate_core_vectors.py')
    assert probes['runner_sha256'] == digest(HERE/'probes.py')
    for row in probes['results']:
        assert row['passed']
        for name in ('log', 'image'):
            assert digest(Path(row[name])) == row[name+'_sha256']
            evidence[row[name]] = row[name+'_sha256']
    inputs = out/'qualified-inputs'
    inputs.mkdir(exist_ok=False)
    preserved = {}
    paths = [*sorted((ROOT/'rtl').glob('*')), ROOT/'Makefile', ROOT/'verilog/filelist.f',
             *sorted((ROOT/'tb').rglob('*')), *sorted((ROOT/'tools').rglob('*')),
             *sorted((ROOT/'tests').rglob('*')), *sorted(HERE.glob('*.py')), HERE/'profile.h']
    for path in paths:
        if not path.is_file():
            continue
        if path.suffix not in ('.v', '.vh', '.py', '.sh', '.cpp', '.c', '.f', '.h') and path.name != 'Makefile':
            continue
        dest = inputs/path.relative_to(ROOT)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(path.read_bytes())
        preserved[str(dest)] = digest(dest)
    result = {'completed': True, 'passed': True, 'baseline_revision': 'abedc8b',
        'framework_revision': selected_snapshot['framework_revision'],
        'configuration': selected_snapshot['configuration'] | {'fetch_line_buffer_entries': 4},
        'baseline': before, 'selected': after,
        'change_percent': {k: (after[k]/before[k]-1)*100 for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
        'estimated_throughput_gain_percent': (after['ipc_geomean']*after['fmax_mhz']/(before['ipc_geomean']*before['fmax_mhz'])-1)*100,
        'ipc_gain_remaining_percent': (1.0985/after['ipc_geomean']-1)*100,
        'joint_tier_three_target_met': after['ipc_geomean'] >= 1.0985,
        'cases': [{'case': a['name'], 'baseline_cycles': a['cycles'], 'selected_cycles': b['cycles']}
                  for a, b in zip(baseline['cases'], selected['cases'])],
        'validation': {'official_programs_per_version': 25, 'line_buffer_configurations': 27,
                       'line_buffer_checks': sum(map(int, checks)), 'unit_lint_hum_response_owner': True,
                       'hum_tests': 28, 'response_owner_checks': owner_checks,
                       'static_configurations': 81, 'static_checks': static_checks,
                       'retirement_traces': retirement_traces, 'program_runs': program_runs},
        'branch_profiles': branch, 'probes': probes['results'], 'evidence_sha256': evidence,
        'preserved_inputs_sha256': preserved}
    (HERE/'results-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS branch restart qualification', result['change_percent'], flush=True)


if __name__ == '__main__':
    main()
