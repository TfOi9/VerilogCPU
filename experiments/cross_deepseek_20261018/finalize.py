#!/usr/bin/env python3
"""Validate the selected improvement against the accepted area baseline."""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/area_20261018'))
from measure import configured_sources, digest, read_sources, save, validate_report


def load(path):
    return json.loads(path.read_text())


def passed(path):
    value = load(path)
    assert value['completed'] and value['passed'], path
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    candidate = args.candidate.resolve()
    root = ROOT / 'build/cross-deepseek-20261018'
    parent = ROOT / 'build/area-codex-20261018'
    config = load(candidate / 'snapshot.json')['configuration']
    snapshot = load(candidate / 'snapshot.json')
    assert all(digest(Path(p)) == h for p, h in snapshot['sha256'].items())
    baseline_perf = passed(parent / 'final/suite-results.json')
    baseline_ppa = passed(parent / 'final/ppa-results.json')['report']
    baseline_snapshot = load(parent / 'final/snapshot.json')
    assert all(digest(Path(p)) == h for p, h in baseline_snapshot['sha256'].items())
    perf = passed(candidate / 'suite-results.json')
    ppa = passed(candidate / 'ppa-results.json')['report']
    validate_report(ppa, 'opt', 2.0)
    validate_report(baseline_ppa, 'opt', 2.0)
    assert len(perf['cases']) == 25
    assert perf['sim_sha256'] == digest(candidate / 'official/sim')
    perf_rows = [p for p in perf['cases'] if 'ipc' in p]
    assert len(perf_rows) == 6
    assert math.isclose(perf['ipc_geomean'], math.exp(sum(math.log(p['dynamic_instructions'] / p['cycles']) for p in perf_rows) / 6), rel_tol=1e-12)
    for row in perf['cases']:
        assert digest(candidate / ('suite-' + row['name'] + '.log')) == row['log_sha256']
    constraints = ('clock_period_ns', 'input_delay_ns', 'output_delay_ns', 'input_transition_ns',
                   'clock_transition_ns', 'clock_uncertainty_ns', 'output_load_ff', 'reset_value',
                   'clock_model', 'interconnect', 'frequency_resolution_ns')
    assert all(ppa['timing'][k] == baseline_ppa['timing'][k] for k in constraints)
    assert ppa['tools'] == baseline_ppa['tools']
    assert ppa['abc_constraints'] == baseline_ppa['abc_constraints']
    assert ppa['sram_model'] == baseline_ppa['sram_model']
    for item in ppa['inputs']:
        assert digest(Path(item['path'])) == item['sha256']
    library_hashes = lambda report: {Path(p['path']).name: p['sha256'] for p in report['libraries']}
    assert library_hashes(ppa) == library_hashes(baseline_ppa)
    projected = root / 'selected-default-input'
    configured_sources(read_sources(ROOT / 'verilog/filelist.f'), (config['FE_WIDTH'], 2, config['PHYS_REGS'], config['ROB_ENTRIES']), projected)
    for path in projected.glob('*.v'):
        assert path.read_bytes() == (candidate / 'input' / path.name).read_bytes(), path
    top = (ROOT / 'rtl/student_top.v').read_text()
    for key, value in config.items():
        assert re.search(r'parameter ' + key + r' = ' + str(value) + r'\s*,', top), key
    focused = passed(candidate / 'focused/results.json')
    mshr = passed(candidate / 'mshr/results.json')
    retirement_root = root / 'fe4-d0-h8/retirement'
    retirement = passed(retirement_root / 'results.json')
    for row in retirement['tests']:
        assert digest(retirement_root / (str(row['seed']) + '.log')) == row['log_sha256']
    for name, expected in retirement['sha256'].items():
        path = Path(name)
        assert digest(path) == expected
        if path.parent.name == 'input':
            assert digest(candidate / 'input' / path.name) == expected
    for path_string, expected in focused['sha256'].items():
        assert digest(Path(path_string)) == expected
    for row in focused['tests']:
        assert digest(candidate / 'focused' / (row['name'] + '.log')) == row['log_sha256']
    for path_string, expected in mshr['sha256'].items():
        assert digest(Path(path_string)) == expected
    for row in mshr['tests']:
        parameters = row['parameters']
        name = str(parameters['LATENCY']) + '-' + str(parameters['SEED'])
        assert digest(candidate / 'mshr' / (name + '.log')) == row['log_sha256']
    matrix_path = parent / 'final-matrix.json'
    matrix = passed(matrix_path)
    assert matrix['sources_unchanged']
    for name, expected in matrix['source_sha256'].items():
        if Path(name).name != 'student_top.v':
            assert digest(Path(name)) == expected, name
    previous_top = subprocess.check_output(['git', 'show', '41752dc:rtl/student_top.v'], cwd=ROOT, text=True)
    normalize = lambda text: re.sub(r'(parameter (?:FE_WIDTH|STORE_DIRECTORY_ENTRIES) = )\d+', r'\g<1>0', text)
    assert normalize(top) == normalize(previous_top)
    old = {'area_um2': baseline_ppa['area']['area_um2'], 'ipc_geomean': baseline_perf['ipc_geomean'],
           'estimated_fmax_mhz': baseline_ppa['timing']['estimated_fmax_mhz']}
    new = {'area_um2': ppa['area']['area_um2'], 'ipc_geomean': perf['ipc_geomean'],
           'estimated_fmax_mhz': ppa['timing']['estimated_fmax_mhz']}
    gates = {'area_strictly_below_110_percent': new['area_um2'] < 1.10 * old['area_um2'],
             'ipc_increased': new['ipc_geomean'] > old['ipc_geomean'],
             'frequency_increased': new['estimated_fmax_mhz'] > old['estimated_fmax_mhz']}
    assert all(gates.values()), gates
    rows = []
    for path in sorted(root.glob('*/screen-results.json')):
        row = passed(path)
        value = {'name': path.parent.name, 'ipc_geomean': row['ipc_geomean'], 'screen_sha256': digest(path)}
        ppa_path = path.parent / 'ppa-results.json'
        if ppa_path.exists():
            candidate_ppa = passed(ppa_path)['report']
            value.update(area_um2=candidate_ppa['area']['area_um2'], estimated_fmax_mhz=candidate_ppa['timing']['estimated_fmax_mhz'], ppa_sha256=digest(ppa_path))
        rows.append(value)
    summary = {'completed': True, 'passed': True, 'baseline_revision': '41752dc',
        'selected': candidate.name, 'configuration': config, 'baseline': old, 'candidate': new,
        'change_percent': {k: 100 * (new[k] / old[k] - 1) for k in old},
        'throughput_proxy_change_percent': 100 * ((new['ipc_geomean'] * new['estimated_fmax_mhz']) / (old['ipc_geomean'] * old['estimated_fmax_mhz']) - 1),
        'area_cap_um2': 1.10 * old['area_um2'], 'gates': gates, 'screens': rows,
        'driver_sha256': {p.name: digest(p) for p in Path(__file__).parent.glob('*.py')},
        'selected_source_sha256': {str(p.relative_to(ROOT)): digest(p)
                                   for p in sorted((ROOT / 'rtl').glob('*')) if p.is_file()},
        'deepseek_reference': {k: v for k, v in load(root / 'deepseek-audit/results.json').items()
                               if k in ('revision', 'branch', 'wrapper_completed', 'wrapper_passed',
                                        'wrapper_sources_unchanged', 'frozen_input_matches_embedded_report_hashes',
                                        'same_native_tools_libraries_and_framework', 'area_um2',
                                        'estimated_fmax_mhz', 'minimum_period_ns', 'note')},
        'evidence_sha256': {str(p.relative_to(ROOT)): digest(p) for p in (
            candidate / 'snapshot.json', candidate / 'suite-results.json', candidate / 'ppa-results.json',
            candidate / 'focused/results.json', candidate / 'mshr/results.json', retirement_root / 'results.json',
            root / 'deepseek-audit/results.json', matrix_path)},
        'validation': {'official_programs': 25, 'retirement_seeds': 3,
            'fresh_focused_checks': len(focused['tests']), 'dual_mshr_cases': len(mshr['tests']),
            'prior_matrix': {'checks': len(matrix['checks']), 'passed': True,
                'full_parameter_elaborations_equivalent': config['STORE_DIRECTORY_ENTRIES'] == 0,
                'scope': 'Unchanged core/component evidence reused. Cache-integrated parameter matrix was not rerun; directory changes are covered by selected integration and focused protocol checks.' if config['STORE_DIRECTORY_ENTRIES'] else 'Only the FE default changed; all matrix commands explicitly override FE. Prior elaborated configurations remain identical.'}}}
    target = Path(__file__).parent / 'results-summary.json'
    save(target, summary)
    print(json.dumps({'candidate': new, 'change_percent': summary['change_percent'], 'gates': gates}))


if __name__ == '__main__':
    main()
