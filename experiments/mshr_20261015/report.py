#!/usr/bin/env python3
"""Verify two-MSHR IPC gains, protocol regressions and official PPA inputs."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'tools'))
from run_synthesis import validate_report
sys.path.insert(0, str(ROOT/'experiments/tier3_20261014'))
from summarize import official_path


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

    def guard(hashes):
        for path, sha in hashes.items():
            assert digest(Path(path)) == sha, path

    def measurement(directory):
        snapshot = read(directory/'snapshot.json')
        guard(snapshot['source_sha256'])
        sim = read(directory/'sim-results.json')
        ppa = read(directory/'ppa-results.json')
        assert all(r['completed'] and r['passed'] for r in (sim, ppa))
        assert all(r['snapshot_sha256'] == digest(directory/'snapshot.json') for r in (sim, ppa))
        assert digest(directory/'official/sim') == sim['sim_sha256']
        assert len(sim['cases']) == len({c['name'] for c in sim['cases']}) == 25
        perf = []
        for row in sim['cases']:
            assert digest(directory/(row['name']+'.log')) == row['log_sha256']
            case = ROOT.parent/'RISC-V-CPU-2026-Testcases'/row['name']
            for name, key in (('program.data', 'image_sha256'), ('expected.txt', 'expected_sha256')):
                assert digest(case/name) == row[key]
            if row['name'].startswith('perf_'):
                assert digest(case/'metrics.json') == row['metrics_sha256']
                assert row['dynamic_instructions'] == json.loads((case/'metrics.json').read_text())['dynamic_instructions']
                assert math.isclose(row['ipc'], row['dynamic_instructions']/row['cycles'], rel_tol=1e-12)
                perf.append(row)
        assert len(perf) == 6
        assert math.isclose(sim['ipc_geomean'], math.exp(sum(math.log(c['ipc']) for c in perf)/6), rel_tol=1e-12)
        guard(ppa['artifact_sha256'])
        report = ppa['report']
        validate_report(report, 'opt', 2.0)
        assert report['tools']['yosys'].startswith('Yosys 0.63 ')
        for item in report['inputs']+report['libraries']:
            assert digest(Path(item['path'])) == item['sha256'], item['path']
        assert report == read(directory/'ppa/opt/report.json')
        assert report['abc_constraints'] == {'driving_cell': 'INVx1_ASAP7_75t_R', 'output_load_ff': 5.0}
        return {'configuration': snapshot['configuration'], 'ipc_geomean': sim['ipc_geomean'],
                'area_um2': report['area']['area_um2'], 'fmax_mhz': report['timing']['estimated_fmax_mhz'],
                'area_breakdown': {k: v for k, v in report['area'].items() if k.endswith('_um2')},
                'minimum_period_ns': report['timing']['minimum_period_ns'],
                'official_path': official_path(directory/'ppa/opt'), 'cases': sim['cases']}

    baseline = ROOT/'build/lsq-return-20261015/parallel'
    selected = out/'prototype5'
    before, after = measurement(baseline), measurement(selected)
    revision = subprocess.check_output(['git', 'rev-parse', '2a34e20'], cwd=ROOT).decode().strip()
    for file in (baseline/'source/rtl').iterdir():
        if file.is_file():
            assert file.read_bytes() == subprocess.check_output(['git', 'show', revision+':rtl/'+file.name], cwd=ROOT)
    for file in (ROOT/'rtl').iterdir():
        if file.is_file():
            assert file.read_bytes() == (selected/'source/rtl'/file.name).read_bytes(), file
    assert {k: v for k, v in after['configuration'].items() if k != 'DCACHE_MSHR_ENTRIES'} == before['configuration']
    assert after['configuration']['DCACHE_MSHR_ENTRIES'] == 2

    gates = read(out/'gates/results.json')
    assert gates['completed'] and gates['passed']
    guard(gates['source_sha256'])
    for row in gates['tests']:
        assert row['exit_code'] == 0 and digest(Path(row['log'])) == row['log_sha256']
    unit = (out/'gates/unit.log').read_text()
    unit_path = re.search(r'PASS MSHR 99 configurations (\S+)', unit)
    assert unit_path
    mshr_dir = Path(unit_path[1])
    mshr = read(mshr_dir/'results.json')
    assert mshr['completed'] and mshr['passed'] and len(mshr['tests']) == 99
    guard(mshr['source_sha256'])
    for test in mshr['tests']:
        assert test['passed']
        guard(test['log_sha256'])
    assert sum(bool(r['expected_rejection']) for r in mshr['tests']) == 3
    source = (ROOT/'rtl/rv32_l1_cache_axi_bridge.v').read_text()
    mutant = re.sub(r'assign d_response_id_o = D_TAGGED != 0.*?;',
                    "assign d_response_id_o = 1'b0;", source, flags=re.S)
    assert (mshr_dir/'untagged_bridge.v').read_text() == mutant
    source = (ROOT/'rtl/rv32_l1_data_cache.v').read_text()
    mutant = re.sub(r'MSHR_ENTRIES == 2 \? !refill_install : \(pipeline_run', '(pipeline_run', source)
    assert (mshr_dir/'disabled_read_cache.v').read_text() == mutant
    for name in ('untagged_bridge.v', 'disabled_read_cache.v'):
        evidence[str(mshr_dir/name)] = digest(mshr_dir/name)
    confirm_path = re.search(r'PASS Store confirmation 64 configurations (\S+)', unit)
    assert confirm_path
    confirm = read(Path(confirm_path[1])/'results.json')
    directory = read(out/'gates/directory/results.json')
    hum = read(out/'gates/hum/results.json')
    owners = read(out/'gates/response-owner/results.json')
    for result in (confirm, directory, hum, owners):
        assert result['passed']
        guard(result['source_sha256'])
    assert len(confirm['tests']) == 64 and len(directory['tests']) == 71
    assert len(hum['tests']) == 28 and len(owners['tests']) == 6

    matrix = read(out/'matrix.json')
    assert matrix['completed'] and matrix['passed'] and matrix['sources_unchanged']
    guard(matrix['source_sha256'])
    assert all(c['passed'] and c['returncode'] == 0 for c in matrix['checks'])
    static = [c for c in matrix['checks'] if c['stage'] in ('iverilog-2005', 'parameter-startup', 'verilator', 'yosys')]
    traces = [c for c in matrix['checks'] if c['stage'].startswith('retirement-')]
    assert len(static) == 324 and len(traces) == 27 and len(matrix['functional']) == 9
    for row in matrix['checks']:
        evidence[str(Path(row['log']).resolve())] = digest(Path(row['log']))
    sys.path.insert(0, str(ROOT.parent/'RISC-V-CPU-2026/scripts'))
    from build import read_sources
    sources = read_sources(ROOT/'verilog/filelist.f')
    headers = sorted({h for p in sources for h in p.parent.glob('*.vh')})
    aggregate = hashlib.sha256()
    for file in sources+headers:
        aggregate.update(file.name.encode()+b'\0'+file.read_bytes())
    for row in matrix['functional']:
        assert row['passed'] and row['rtl_sha256'] == aggregate.hexdigest()
        assert all(c['passed'] for c in row['results'])
        for case in row['results']:
            evidence[str(Path(case['log']).resolve())] = digest(Path(case['log']))

    profiles = {}
    for label in ('before', 'after', 'control-one'):
        root = out/'profiles'/label
        result = read(root/'results.json')
        assert result['completed'] and result['passed'] and len(result['cases']) == 6
        guard(result['source_sha256'])
        assert digest(root/'sim') == result['sim_sha256']
        snapshot = baseline if label == 'before' else selected
        for file in (root/'source/rtl').iterdir():
            if file.is_file():
                assert file.read_bytes() == (snapshot/'source/rtl'/file.name).read_bytes()
        official_cases = {c['name']: c for c in (after if label == 'after' else before)['cases']}
        for case in result['cases']:
            assert case['cycles'] == official_cases[case['name']]['cycles']
            assert digest(root/(case['name']+'.log')) == case['log_sha256']
        profiles[label] = {c['name']: c for c in result['cases']}
    for name in profiles['before']:
        assert profiles['before'][name]['profile'] == profiles['control-one'][name]['profile']
    vv_before = profiles['before']['perf_vvadd']['profile']
    vv_after = profiles['after']['perf_vvadd']['profile']
    assert vv_after['counts']['merged_requests'] > 0
    assert vv_after['counts']['mshr_occupancy_2'] > 0 and vv_after['counts']['two_d_reads_in_bridge'] > 0
    assert vv_after['counts']['refills'] == vv_before['counts']['refills']
    assert vv_after['counts']['blocked_second_miss'] < vv_before['counts']['blocked_second_miss']

    trace = read(out/'path-trace/results.json')
    assert trace['completed'] and trace['passed']
    guard(trace['source_sha256'])
    guard(trace['official_sha256'])
    failure = out/'prototype1/perf_qsort.log'
    preserved_failure = None
    if failure.exists():
        assert 'ERROR rv32_l1_data_cache irrevocable store lost its line' in failure.read_text()
        evidence[str(failure)] = digest(failure)
        guard(read(out/'prototype1/snapshot.json')['source_sha256'])
        preserved_failure = 'Prototype 1 qsort exposed an S1 SRAM read disable during merged responses; fixed by retaining reads except during installation.'
    rows = []
    old_cases = {c['name']: c for c in before['cases']}
    for case in after['cases']:
        if case['name'].startswith('perf_'):
            previous = old_cases[case['name']]
            assert case['ipc'] >= previous['ipc']
            rows.append({'name': case['name'], 'baseline_cycles': previous['cycles'],
                         'selected_cycles': case['cycles'], 'baseline_ipc': previous['ipc'],
                         'selected_ipc': case['ipc'], 'ipc_change_percent': (case['ipc']/previous['ipc']-1)*100})
    assert after['ipc_geomean'] > before['ipc_geomean'] and after['area_um2'] <= 36000 and after['fmax_mhz'] >= 300
    result = {'completed': True, 'passed': True, 'baseline_revision': revision,
              'reporter_sha256': digest(Path(__file__)), 'baseline': before, 'selected': after,
              'change_percent': {k: (after[k]/before[k]-1)*100 for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
              'estimated_throughput_change_percent': (after['ipc_geomean']*after['fmax_mhz']/
                  (before['ipc_geomean']*before['fmax_mhz'])-1)*100,
              'ipc_per_area_change_percent': ((after['ipc_geomean']/after['area_um2'])/
                  (before['ipc_geomean']/before['area_um2'])-1)*100,
              'joint_tier_three_target_met': after['ipc_geomean'] >= 1.0985 and
                  after['area_um2'] <= 36000 and after['fmax_mhz'] >= 300,
              'cases': rows, 'vvadd_profile_before': vv_before, 'vvadd_profile_after': vv_after,
              'single_mshr_control_matches_baseline': True, 'critical_path': trace['paths'][0],
              'regression': {'official_cases': 25, 'mshr_configurations': len(mshr['tests']),
                  'mshr_cache_responses': sum(t['counts'].get('checks', 0) for t in mshr['tests']),
                  'mshr_bridge_responses': sum(t['counts'].get('responses', 0) for t in mshr['tests']),
                  'mshr_negative_controls': 3, 'static_checks': len(static), 'retirement_traces': len(traces),
                  'functional_programs': sum(len(r['results']) for r in matrix['functional']),
                  'store_confirmation_configurations': len(confirm['tests']),
                  'directory_configurations': len(directory['tests']), 'hum_checks': len(hum['tests']),
                  'response_boundary_checks': sum(c['checks'] for c in owners['tests'])},
              'preserved_failure': preserved_failure,
              'evidence_sha256': evidence}
    text = json.dumps(result, indent=2)+'\n'
    (out/'results-summary.json').write_text(text)
    (HERE/'results-summary.json').write_text(text)
    print(json.dumps({k: result[k] for k in ('change_percent', 'cases', 'regression', 'critical_path')}, indent=2))


if __name__ == '__main__':
    main()
