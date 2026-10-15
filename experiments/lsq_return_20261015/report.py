#!/usr/bin/env python3
"""Verify the final RTL, complete regressions and official before/after PPA."""
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

    baseline = ROOT/'build/store-confirm-20261015/final128'
    selected = out/'parallel'
    before, after = measurement(baseline), measurement(selected)
    for file in (baseline/'source/rtl').iterdir():
        if file.is_file():
            original = subprocess.check_output(['git', 'show', 'bcd3f31:rtl/'+file.name], cwd=ROOT)
            assert file.read_bytes() == original, file
    for file in (ROOT/'rtl').iterdir():
        if file.is_file():
            assert file.read_bytes() == (selected/'source/rtl'/file.name).read_bytes(), file
    assert before['configuration'] == after['configuration']
    cycles = lambda r: {c['name']: c['cycles'] for c in r['cases']}
    assert cycles(before) == cycles(after)

    equivalence = read(out/'equivalence-fixed/results.json')
    assert equivalence['completed'] and equivalence['passed'] and len(equivalence['tests']) == 26
    guard(equivalence['source_sha256'])
    for row in equivalence['tests']:
        assert row['passed'] and digest(Path(row['log'])) == row['log_sha256']
    gates = read(out/'gates/results.json')
    assert gates['completed'] and gates['passed']
    guard(gates['source_sha256'])
    for row in gates['tests']:
        assert row['exit_code'] == 0 and digest(Path(row['log'])) == row['log_sha256']
    unit = (out/'gates/unit.log').read_text()
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

    diagnostic = {}
    for label in ('baseline-boundaries', 'selected-boundaries', 'path-trace-final'):
        result = read(out/label/'results.json')
        assert result['completed'] and result['passed']
        guard(result['source_sha256'])
        guard(result['official_sha256'])
        if 'artifact_sha256' in result:
            guard(result['artifact_sha256'])
        diagnostic[label] = result['paths'][0]
    assert diagnostic['selected-boundaries']['arrival_ns'] < diagnostic['baseline-boundaries']['arrival_ns']
    assert after['fmax_mhz'] > before['fmax_mhz'] and after['area_um2'] <= 36000
    preserved_failures = {}
    fixture_log = out/'equivalence/be1-rob16-rs8-store0-run.log'
    if fixture_log.exists():
        assert 'ERROR rv32_memory_reservation_station invalid parameters' in fixture_log.read_text()
        evidence[str(fixture_log)] = digest(fixture_log)
        preserved_failures['fixture'] = 'Missing ROB_ENTRIES override in the first equivalence test; fixed the testbench, with no RTL change.'
    early_trace_log = out/'path-trace.log'
    if early_trace_log.exists():
        assert 'assert all(digest(Path(p)) == h for p, h in official.items())' in early_trace_log.read_text()
        evidence[str(early_trace_log)] = digest(early_trace_log)
        preserved_failures['diagnostic'] = 'The first path trace overlapped official report generation; its integrity guard rejected it. Repeated after official measurement completed.'
    result = {'completed': True, 'passed': True, 'baseline_revision': equivalence['reference_revision'],
              'reporter_sha256': digest(Path(__file__)),
              'baseline': before, 'selected': after,
              'change_percent': {k: (after[k]/before[k]-1)*100 for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
              'estimated_throughput_change_percent': (after['ipc_geomean']*after['fmax_mhz']/
                  (before['ipc_geomean']*before['fmax_mhz'])-1)*100,
              'ipc_per_area_change_percent': ((after['ipc_geomean']/after['area_um2'])/
                  (before['ipc_geomean']/before['area_um2'])-1)*100,
              'diagnostic_paths': diagnostic,
              'regression': {'official_cases': 25, 'identical_official_cycles': True,
                  'equivalence_configurations': len(equivalence['tests']),
                  'equivalence_checks': sum(c['checks'] for c in equivalence['tests']),
                  'static_checks': len(static), 'retirement_traces': len(traces),
                  'functional_programs': sum(len(r['results']) for r in matrix['functional']),
                  'store_confirmation_configurations': len(confirm['tests']),
                  'directory_configurations': len(directory['tests']), 'hum_checks': len(hum['tests']),
                  'response_boundary_checks': sum(c['checks'] for c in owners['tests'])},
              'preserved_failures': preserved_failures,
              'evidence_sha256': evidence}
    text = json.dumps(result, indent=2)+'\n'
    (out/'results-summary.json').write_text(text)
    (HERE/'results-summary.json').write_text(text)
    print(json.dumps({k: result[k] for k in ('change_percent', 'regression', 'diagnostic_paths')}, indent=2))


if __name__ == '__main__':
    main()
