#!/usr/bin/env python3
"""Reject incomplete evidence or regressions beyond the requested 3% gates."""
import argparse
import json
import math
from pathlib import Path

from measure import ROOT, digest, save
from run_synthesis import omit_empty_connections, validate_report


def read(path):
    return json.loads(path.read_text())


def passed(path):
    value = read(path)
    assert value['completed'] and value['passed'], path
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    run = ROOT / 'build/area-codex-20261018'
    candidate = args.candidate.resolve()
    reference = passed(run / 'reference/screen-results.json')
    performance = passed(candidate / 'suite-results.json')
    synthesis = passed(candidate / 'ppa-results.json')
    for directory, phase, record in ((run / 'reference', 'screen', reference), (candidate, 'suite', performance)):
        perf = []
        assert digest(directory / 'official/sim') == record['sim_sha256']
        for row in record['cases']:
            log = directory / (phase + '-' + row['name'] + '.log')
            assert digest(log) == row['log_sha256']
            assert isinstance(row['cycles'], int) and row['cycles'] > 0
            if 'ipc' in row:
                value = row['dynamic_instructions'] / row['cycles']
                assert math.isclose(value, row['ipc'], rel_tol=1e-12)
                perf.append(value)
        assert len(perf) == 6
        mean = math.exp(math.fsum(map(math.log, perf)) / 6)
        assert math.isclose(mean, record['ipc_geomean'], rel_tol=1e-12)
    matrix = passed(run / 'final-matrix.json')
    assert matrix['sources_unchanged']
    assert matrix['all_performance'] and len(matrix['matrix']) == 81
    assert len(matrix['checks']) == 381 and len(matrix['functional']) == 9
    assert all(row['passed'] for row in matrix['checks'])
    for row in matrix['functional']:
        assert row['completed'] and row['passed'] and row['all_performance']
        assert len(row['results']) == 27 and all(case['passed'] for case in row['results'])
        assert sum(case['case'].startswith('perf_') for case in row['results']) == 6
    gates = passed(run / 'gates.json')
    proof = passed(run / 'prf-proof-verified/results.json')
    retirement = passed(run / 'selected-retirement/results.json')
    hints = passed(run / 'hints8-protocol/results.json')
    capacity = passed(run / 'capacity-unit/results.json')
    reset_results = []
    for path in (ROOT / 'build/prf-reset-unit').rglob('results.json'):
        value = read(path)
        if value['passed'] and len(value['tests']) == 15 and all(
                digest(Path(p)) == h for p, h in value['sha256'].items()):
            reset_results.append(path)
    assert reset_results
    reset_path = max(reset_results, key=lambda p: p.stat().st_mtime_ns)
    snapshot = read(candidate / 'snapshot.json')
    assert performance['configuration'] == synthesis['configuration'] == snapshot['configuration']
    assert all(digest(Path(p)) == h for p, h in snapshot['sha256'].items())
    for source in (ROOT / 'rtl').glob('*'):
        if source.suffix == '.v':
            assert omit_empty_connections(source.read_text()) == (candidate / 'input' / source.name).read_text(), source
        elif source.suffix == '.vh':
            assert source.read_bytes() == (candidate / 'input' / source.name).read_bytes(), source
    audit = read(run / 'baseline-ppa-audit.json')
    assert audit['passed'] and digest(Path(audit['report_path'])) == audit['report_sha256']
    baseline = read(Path(audit['report_path']))
    current = synthesis['report']
    for report in (baseline, current):
        validate_report(report, 'opt', 2.0)
    assert baseline['abc_constraints'] == current['abc_constraints']
    assert baseline['tools'] == current['tools']
    assert baseline['sram_model'] == current['sram_model']
    assert {Path(p['path']).name: p['sha256'] for p in baseline['libraries']} == {
        Path(p['path']).name: p['sha256'] for p in current['libraries']}
    for key in ('clock_period_ns', 'input_delay_ns', 'output_delay_ns', 'input_transition_ns',
                'clock_transition_ns', 'clock_uncertainty_ns', 'output_load_ff', 'reset_value',
                'clock_model', 'interconnect', 'frequency_resolution_ns'):
        assert baseline['timing'][key] == current['timing'][key], key
    area = current['area']['area_um2']
    frequency = current['timing']['estimated_fmax_mhz']
    ipc = performance['ipc_geomean']
    changes = {'area_percent': 100 * (area / audit['area_um2'] - 1),
               'fmax_percent': 100 * (frequency / audit['fmax_mhz'] - 1),
               'ipc_percent': 100 * (ipc / reference['ipc_geomean'] - 1)}
    assert changes['area_percent'] < 0
    assert changes['fmax_percent'] >= -3 and changes['ipc_percent'] >= -3, changes
    before = {row['name']: row for row in reference['cases']}
    rows = []
    for row in performance['cases']:
        if 'ipc' in row:
            old = before[row['name']]
            assert old['dynamic_instructions'] == row['dynamic_instructions']
            rows.append({'name': row['name'], 'before_cycles': old['cycles'], 'cycles': row['cycles'],
                         'ipc_percent': 100 * (row['ipc'] / old['ipc'] - 1)})
    assert len(rows) == 6 and len(performance['cases']) == 25
    paths = [candidate / 'snapshot.json', candidate / 'suite-results.json', candidate / 'ppa-results.json',
             run / 'baseline-ppa-audit.json', run / 'reference/screen-results.json',
             run / 'final-matrix.json', run / 'gates.json', run / 'prf-proof-verified/results.json',
             run / 'selected-retirement/results.json', run / 'hints8-protocol/results.json', reset_path]
    paths.append(run / 'capacity-unit/results.json')
    result = {'completed': True, 'passed': True, 'baseline_commit': audit['baseline_commit'],
              'configuration': snapshot['configuration'],
              'baseline': {'area_um2': audit['area_um2'], 'fmax_mhz': audit['fmax_mhz'],
                           'ipc_geomean': reference['ipc_geomean']},
              'candidate': {'area_um2': area, 'fmax_mhz': frequency, 'ipc_geomean': ipc,
                            'sram_area_um2': current['area']['sram_area_um2']},
              'changes': changes, 'cases': rows,
              'scope': {'official_programs': 25, 'matrix_checks': len(matrix['checks']),
                        'matrix_configurations': len(matrix['matrix']),
                        'matrix_program_runs': sum(len(row['results']) for row in matrix['functional']),
                        'matrix_retirement_traces': sum(row['stage'].startswith('retirement-') for row in matrix['checks']),
                        'prf_and_rename_tests': len(read(reset_path)['tests']) + len(capacity['tests']),
                        'inductive_proofs': len(proof['tests']), 'selected_retirement_traces': len(retirement['tests']),
                        'wide_formal_proof': 'inconclusive at 120 seconds; simulation matrix required'},
              'acceptance': {'ipc_metric': 'geometric mean of all six official perf_* programs',
                             'max_independent_ipc_and_fmax_regression_percent': 3,
                             'per_program_regression_limit': None},
              'evidence_sha256': {str(p): digest(p) for p in paths},
              'source_sha256': {str(p): digest(p) for p in (ROOT / 'rtl').glob('*') if p.is_file()}}
    save(Path(__file__).with_name('results-summary.json'), result)
    print(json.dumps(result['changes']), flush=True)


if __name__ == '__main__':
    main()
