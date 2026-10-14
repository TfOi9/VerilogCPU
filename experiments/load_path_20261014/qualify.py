#!/usr/bin/env python3
"""Audit completed gates and preserve their exact source inputs before editing."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/load-path-20261014'
HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', required=True)
    parser.add_argument('--measurement', required=True)
    args = parser.parse_args()
    stage = args.stage
    measurement = OUT/args.measurement
    inputs = {}
    evidence = {}

    def read(path):
        evidence[str(path)] = digest(path)
        return json.loads(path.read_text())

    def collect(record, key='source_sha256'):
        for path, sha in record[key].items():
            assert path not in inputs or inputs[path] == sha, path
            inputs[path] = sha

    snapshot = read(measurement/'snapshot.json')
    collect(snapshot)
    for path in (ROOT/'rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (measurement/'source/rtl'/path.name).read_bytes(), path
    sim = read(measurement/'sim-results.json')
    ppa = read(measurement/'ppa-results.json')
    for record in (sim, ppa):
        assert record['completed'] and record['passed']
        assert record['snapshot_sha256'] == digest(measurement/'snapshot.json')
    assert digest(measurement/'official/sim') == sim['sim_sha256']
    for case in sim['cases']:
        assert digest(measurement/(case['name']+'.log')) == case['log_sha256']
        original = ROOT.parent/'RISC-V-CPU-2026-Testcases'/case['name']
        assert digest(original/'program.data') == case['image_sha256']
        assert digest(original/'expected.txt') == case['expected_sha256']
        if 'metrics_sha256' in case:
            assert digest(original/'metrics.json') == case['metrics_sha256']
    for path, sha in ppa['artifact_sha256'].items():
        assert digest(Path(path)) == sha, path
    assert ppa['report']['area']['area_um2'] <= 36000
    assert ppa['report']['timing']['estimated_fmax_mhz'] >= 300
    matrix = read(OUT/(stage+'-matrix.json'))
    assert matrix['completed'] and matrix['passed'] and matrix['sources_unchanged']
    collect(matrix)
    checks = matrix['checks']
    assert all(c['passed'] for c in checks)
    static = [c for c in checks if c['stage'] in ('iverilog-2005', 'parameter-startup', 'verilator', 'yosys')]
    retirement = [c for c in checks if c['stage'].startswith('retirement-')]
    assert len(static) == 324 and len(retirement) == 27
    functional = [r for c in matrix['functional'] for r in c['results']]
    assert len(matrix['functional']) == 9 and all(r['passed'] for r in functional)
    for c in checks:
        evidence[c['log']] = digest(Path(c['log']))
    hum = read(OUT/(stage+'-hum/results.json'))
    assert hum['completed'] and hum['passed'] and hum['sources_unchanged']
    assert len(hum['tests']) == 28
    collect(hum)
    deep = read(OUT/(stage+'-deep.json'))
    assert deep['completed'] and deep['passed'] and deep['sources_unchanged']
    collect(deep)
    boundary = read(ROOT/'build/response-owner-unit/results.json')
    assert boundary['passed'] and sum(t['checks'] for t in boundary['tests']) == 7168
    collect(boundary)
    gates = read(OUT/(stage+'-gates.json'))
    assert gates['exit_code'] == 0
    for path, sha in gates['logs'].items():
        assert digest(Path(path)) == sha
    destination = OUT/(stage+'-qualified-inputs')
    preserved = []
    for original, sha in inputs.items():
        path = Path(original).resolve()
        assert digest(path) == sha, original
        if path.is_relative_to(ROOT) and path.relative_to(ROOT).parts[0] in ('rtl', 'tb', 'tools'):
            target = destination/path.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
        else:
            target = path
        preserved.append({'original': original, 'frozen': str(target), 'sha256': sha})
    for name in ('deep-unit', 'response-owner-unit'):
        shutil.copytree(ROOT/'build'/name, OUT/(stage+'-'+name+'-archive'), dirs_exist_ok=True)
    result = {'completed': True, 'passed': True, 'stage': stage,
        'measurement': str(measurement), 'framework_revision': snapshot['framework_revision'],
        'ipc_geomean': sim['ipc_geomean'], 'area_um2': ppa['report']['area']['area_um2'],
        'fmax_mhz': ppa['report']['timing']['estimated_fmax_mhz'],
        'minimum_period_ns': ppa['report']['timing']['minimum_period_ns'],
        'validation': {'official_programs': len(sim['cases']), 'matrix_static_checks': len(static),
            'matrix_retirement_traces': len(retirement), 'matrix_programs': len(functional),
            'hum_tests': len(hum['tests']), 'deep_unit_configurations': len(deep['tests']),
            'response_boundary_checks': sum(t['checks'] for t in boundary['tests']),
            'unit_and_lint_exit_code': 0},
        'cases': sim['cases'], 'preserved_inputs': preserved, 'evidence_sha256': evidence}
    (HERE/(stage+'-results.json')).write_text(json.dumps(result, indent=2)+'\n')
    print('PASS qualified', stage, result['validation'], result['ipc_geomean'],
          result['area_um2'], result['fmax_mhz'])


if __name__ == '__main__':
    main()
