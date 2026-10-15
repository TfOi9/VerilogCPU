#!/usr/bin/env python3
"""Audit the Store directory against frozen official simulation and PPA."""
import argparse
import hashlib
import json
import math
from pathlib import Path

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
        evidence[str(path)] = digest(path)
        return json.loads(path.read_text())

    def snapshot(directory):
        record = read(directory/'snapshot.json')
        assert record['framework_revision'] == '302f0cf3cccdaa5de084a2120e0d950c663e4cf5'
        for path, sha in record['source_sha256'].items():
            assert digest(Path(path)) == sha, path
        return record

    def simulation(directory):
        record = read(directory/'sim-results.json')
        assert record['completed'] and record['passed']
        assert record['snapshot_sha256'] == digest(directory/'snapshot.json')
        assert record['sim_sha256'] == digest(directory/'official/sim')
        official = {p.name for p in (ROOT.parent/'RISC-V-CPU-2026-Testcases').iterdir()
                    if (p/'program.data').exists()}
        assert len(official) == 25 and {c['name'] for c in record['cases']} == official
        for case in record['cases']:
            assert digest(directory/(case['name']+'.log')) == case['log_sha256']
            source = ROOT.parent/'RISC-V-CPU-2026-Testcases'/case['name']
            assert digest(source/'program.data') == case['image_sha256']
            assert digest(source/'expected.txt') == case['expected_sha256']
            if case['name'].startswith('perf_'):
                assert digest(source/'metrics.json') == case['metrics_sha256']
                n = json.loads((source/'metrics.json').read_text())['dynamic_instructions']
                assert n == case['dynamic_instructions'] and case['ipc'] == n/case['cycles']
        perf = [r['ipc'] for r in record['cases'] if r['name'].startswith('perf_')]
        assert len(perf) == 6 and math.exp(sum(map(math.log, perf))/6) == record['ipc_geomean']
        return record

    def ppa(directory):
        record = read(directory/'ppa-results.json')
        assert record['completed'] and record['passed']
        assert record['snapshot_sha256'] == digest(directory/'snapshot.json')
        for path, sha in record['artifact_sha256'].items():
            assert digest(Path(path)) == sha, path
        report = record['report']
        for item in report['inputs']+report['libraries']:
            assert digest(Path(item['path'])) == item['sha256']
        assert report['abc_constraints'] == {'driving_cell': 'INVx1_ASAP7_75t_R', 'output_load_ff': 5.0}
        return {'area_um2': report['area']['area_um2'],
                'fmax_mhz': report['timing']['estimated_fmax_mhz'],
                'minimum_period_ns': report['timing']['minimum_period_ns']}

    prior = ROOT/'build/branch-restart-20261015/selected'
    snapshot(prior)
    selected_snapshot = snapshot(out/'selected')
    snapshot(out/'be4-baseline')
    for path in (out/'be4-baseline/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (prior/'source/rtl'/path.name).read_bytes()
    for path in (out/'selected/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (ROOT/'rtl'/path.name).read_bytes(), path
    before_sim = simulation(prior)
    after_sim = simulation(out/'selected')
    be4_sim = simulation(out/'be4-baseline')
    before = ppa(prior) | {'ipc_geomean': before_sim['ipc_geomean']}
    after = ppa(out/'selected') | {'ipc_geomean': after_sim['ipc_geomean']}
    be4 = ppa(out/'be4-baseline') | {'ipc_geomean': be4_sim['ipc_geomean']}
    assert after['area_um2'] <= 36000 and after['fmax_mhz'] >= 300
    assert after['ipc_geomean'] > before['ipc_geomean']
    throughput_gain = 100*(after['ipc_geomean']*after['fmax_mhz']/
                          (before['ipc_geomean']*before['fmax_mhz'])-1)
    assert throughput_gain > 0
    profile = read(out/'profile-final/results.json')
    assert profile['completed'] and profile['passed'] and profile['sources_unchanged']
    audit = read(out/'profile-final/input-audit.json')
    assert audit['unchanged']
    for record in (profile['runner_sha256'], audit['input_sha256'], profile['rtl_sha256']):
        for path, sha in record.items():
            assert digest(Path(path)) == sha, path
    candidate = profile['results'][0]
    assert candidate['variant'] == 'be2-dir256' and candidate['geomean'] == after['ipc_geomean']
    for path, sha in candidate['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    for path in (out/'selected/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (out/'profile-final/be2-dir256/source/rtl'/path.name).read_bytes()
    cycles = {r['name']: r['cycles'] for r in after_sim['cases']}
    for case in candidate['cases']:
        assert case['cycles'] == cycles[case['case']]
        for suffix in ('stdout', 'stderr'):
            assert digest(out/'profile-final/be2-dir256'/(case['case']+'.'+suffix)) == case[suffix+'_sha256']
        counts = case['profile']['counts']
        assert sum(v for k, v in counts.items() if k.startswith('partition_')) == case['cycles']
        assert sum(v for k, v in counts.items() if k.startswith('store_stage_')) == counts.get('partition_head_store_response', 0)
        assert counts['detail_posted_ram_stores'] <= counts['detail_accepted_ram_stores']
    gates = read(out/'gates/results.json')
    assert gates['completed'] and gates['passed'] and len(gates['tests']) == 4
    for row in gates['tests']:
        assert row['exit_code'] == 0 and digest(Path(row['log'])) == row['log_sha256']
    for path, sha in gates['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    directory = read(out/'gates/directory/results.json')
    assert directory['completed'] and directory['passed'] and directory['sources_unchanged']
    assert len(directory['tests']) == 71
    for path, sha in directory['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    for row in directory['tests']:
        assert row['passed'] and digest(Path(row['log'])) == row['log_sha256']
    hum = read(out/'gates/hum/results.json')
    owner = read(out/'gates/response-owner/results.json')
    assert hum['completed'] and hum['passed'] and hum['sources_unchanged'] and len(hum['tests']) == 28
    assert owner['passed'] and sum(r['checks'] for r in owner['tests']) == 7168
    for record in (hum, owner):
        for path, sha in record['source_sha256'].items():
            assert digest(Path(path)) == sha, path
    matrix = read(out/'matrix.json')
    assert matrix['completed'] and matrix['passed'] and matrix['sources_unchanged']
    assert len(matrix['matrix']) == 81 and len(matrix['representatives']) == 9
    for path, sha in matrix['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    for row in matrix['checks']:
        assert row['passed'] and row['returncode'] == 0
        assert Path(row['log']).exists()
    static = sum(r['stage'] in ('iverilog-2005', 'parameter-startup', 'verilator', 'yosys') for r in matrix['checks'])
    traces = sum(r['stage'].startswith('retirement-') for r in matrix['checks'])
    programs = sum(len(r['results']) for r in matrix['functional'])
    assert static == 324 and traces == 27 and programs == 243
    probes = read(out/'probes/results.json')
    assert probes['completed'] and probes['passed'] and len(probes['results']) == 12
    for path, sha in probes['input_sha256'].items():
        assert digest(Path(path)) == sha, path
    probe_summary = []
    for lines in (32, 64, 96):
        rows = [r for r in probes['results'] if r['lines'] == lines]
        for r in rows:
            assert r['passed']
            log = out/'probes'/f'store-ring-{lines}-{r["stage"]}-{r["mode"]}.log'
            assert digest(log) == r['log_sha256']
            assert digest(out/'probes'/f'store-ring-{lines}.data') == r['image_sha256']
        a = next(r for r in rows if r['stage'] == 'baseline' and r['mode'] == 'official')
        b = next(r for r in rows if r['stage'] == 'selected' and r['mode'] == 'official')
        probe_summary.append({'lines': lines, 'instructions': a['instructions'], 'baseline_cycles': a['cycles'],
                              'selected_cycles': b['cycles'], 'ipc_gain_percent': 100*(a['cycles']/b['cycles']-1)})
    old_record = read(ROOT/'build/next-optimization-20261015/sensitivity/results.json')
    assert old_record['completed'] and old_record['passed']
    old_profile = old_record['results'][0]
    for path, sha in old_profile['source_sha256'].items():
        assert digest(Path(path)) == sha, path
    for path in (ROOT/'build/next-optimization-20261015/sensitivity/baseline/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (prior/'source/rtl'/path.name).read_bytes()
    old_counts = {r['case']: r['profile']['counts'] for r in old_profile['cases']}
    cases = []
    for r in candidate['cases']:
        c = r['profile']['counts']; old = old_counts[r['case']]
        base = next(x for x in before_sim['cases'] if x['name'] == r['case'])
        cases.append({'case': r['case'], 'baseline_cycles': base['cycles'], 'selected_cycles': r['cycles'],
                      'ipc_gain_percent': 100*(base['cycles']/r['cycles']-1),
                      'posted_stores_before': old['detail_posted_ram_stores'],
                      'posted_stores_after': c['detail_posted_ram_stores'],
                      'missing_proof_before': old.get('detail_store_no_hint', 0),
                      'missing_proof_after': c.get('detail_store_no_hint', 0)})
    evidence[str(Path(__file__))] = digest(Path(__file__))
    summary = {'completed': True, 'passed': True, 'baseline_revision': '3f0636c',
               'configuration': selected_snapshot['configuration'] | {'RECOVERY_WIDTH': 4, 'latency': 10},
               'baseline': before, 'selected': after, 'be4_rejected': be4,
               'change_percent': {k: 100*(after[k]/before[k]-1) for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
               'estimated_throughput_gain_percent': throughput_gain,
               'joint_tier_three_target_met': after['ipc_geomean'] >= 1.0985,
               'ipc_gain_remaining_percent': 100*(1.0985/after['ipc_geomean']-1),
               'cases': cases, 'probes': probe_summary,
               'validation': {'official_programs_per_version': 25, 'directory_configurations': 71,
                              'directory_checks': sum(r.get('checks') or 0 for r in directory['tests']),
                              'hum_configurations': 28, 'response_owner_checks': 7168,
                              'matrix_configurations': 81, 'matrix_static_checks': static,
                              'matrix_retirement_traces': traces, 'matrix_program_runs': programs},
               'preserved_failed_runs': {'unit-v1': 'fixture coverage count assumed an optional alias case',
                                        'unit-hash': 'refill address bit selection fixed before revalidation',
                                        'screen-hash': 'interrupted after the directed failure; not qualified'},
               'evidence_sha256': evidence}
    (HERE/'results-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print('PASS Store directory qualification', json.dumps(after), flush=True)


if __name__ == '__main__':
    main()
