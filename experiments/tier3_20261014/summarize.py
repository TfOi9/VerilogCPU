#!/usr/bin/env python3
"""Validate current-source evidence and emit compact investigation tables."""
import hashlib
import json
import math
from pathlib import Path
import sys
from collections import Counter

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT/'build/tier3-20261014'
sys.path.insert(0, str(ROOT/'experiments/round3_electrical'))
from hold import instance_map, resolve_pin


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compact_ppa(report):
    return {'area_um2': report['area']['area_um2'],
            'fmax_mhz': report['timing']['estimated_fmax_mhz'],
            'minimum_period_ns': report['timing']['minimum_period_ns']}


def official_path(directory):
    top = json.loads((directory/'design.json').read_text())['modules']['student_top']
    names = instance_map(top, (directory/'mapped.v').read_text())
    check = json.loads((directory/'critical_paths.json').read_text())['checks'][0]
    fanout = Counter(b for cell in top['cells'].values() for port, bits in cell['connections'].items()
                     if cell['port_directions'][port] == 'input' for b in bits)
    stages = []
    for before, after in zip(check['source_path'], check['source_path'][1:]):
        if not after['instance'] or before['instance'] != after['instance']:
            continue
        if after['cell'].startswith('DFF'):
            continue
        stages.append({'cell': after['cell'], 'delay_ns': (after['arrival']-before['arrival'])*1e9,
                       'fanout': fanout[resolve_pin(top, names, after['pin'])]})
    result = {'arrival_ns': check['source_path'][-1]['arrival']*1e9,
              'combinational_stages': len(stages),
              'buffers_inverters': sum(s['cell'].startswith(('BUF', 'INV')) for s in stages),
              'max_path_fanout': max(s['fanout'] for s in stages)}
    for boundary in ('startpoint', 'endpoint'):
        pin = check[boundary]
        cell = top['cells'][names[pin.rsplit('/', 1)[0]]]
        result[boundary] = {'pin': pin, 'src': cell.get('attributes', {}).get('src')}
    return result


def main():
    evidence = {}

    def read(path):
        evidence[str(path)] = digest(path)
        return json.loads(path.read_text())

    screen = read(OUT/'profile/results.json')
    audit = read(OUT/'profile/input-audit.json')
    assert screen['completed'] and screen['passed'] and audit['unchanged']
    for p, h in audit['input_sha256'].items():
        assert digest(Path(p)) == h, p
    rows = []
    for variant in screen['results']:
        sim = OUT/'profile'/variant['variant']/'sim'
        assert digest(sim) == variant['sim_sha256']
        for p, h in variant['source_sha256'].items():
            assert digest(Path(p)) == h, p
        assert len(variant['cases']) == 6
        for c in variant['cases']:
            for stream in ('stdout', 'stderr'):
                assert digest(sim.parent/(c['case']+'.'+stream)) == c[stream+'_sha256']
        rows.append({'variant': variant['variant'], 'ipc': variant['geomean'],
                     'parameters': variant['parameters'], 'snapshot_edits': variant['snapshot_edits'],
                     'gain_percent': (variant['geomean']/screen['results'][0]['geomean']-1)*100,
                     'cycles': {c['case']: c['cycles'] for c in variant['cases']}})
    baseline = screen['results'][0]
    old = read(ROOT/'experiments/hum_20261014/results-summary.json')
    assert [c['cycles'] for c in baseline['cases']] == [c['cycles'] for c in old['cases']]
    snapshot = Path(old['selected_snapshot'])
    for p in (ROOT/'rtl').glob('*'):
        if p.is_file():
            assert digest(p) == digest(snapshot/'rtl'/p.name)
    ppa_path = ROOT/'build/hum-20261014/ppa-v6/results.json'
    ppa = read(ppa_path)
    assert ppa['completed'] and ppa['passed']
    assert read(Path(ppa['final_directory'])/'report.json') == ppa['report']
    for p, h in ppa['source_sha256'].items():
        assert digest(Path(p)) == h, p
    latency = read(OUT/'latency/results.json')
    assert latency['passed'] and latency['unchanged']
    for p, h in latency['input_sha256'].items():
        assert digest(Path(p)) == h
    for row in latency['results']:
        for c in row['cases']:
            for stream in ('stdout', 'stderr'):
                path = OUT/'latency'/(c['case']+'-l'+str(row['latency'])+'.'+stream)
                assert digest(path) == c[stream+'_sha256']
    probes = read(OUT/'probes/results.json')
    assert probes['completed'] and probes['passed'] and probes['sim_sha256'] == baseline['sim_sha256']
    for row in probes['results']:
        assert digest(OUT/'probes'/(row['probe']+'.data')) == row['image_sha256']
        evidence[str(OUT/'probes'/(row['probe']+'.log'))] = digest(OUT/'probes'/(row['probe']+'.log'))
    paths = read(OUT/'path-audit.json')
    assert paths['passed']
    for p, h in paths['source_sha256'].items():
        assert digest(Path(p)) == h
    mux = read(OUT/'response-mux/results.json')
    assert mux['completed'] and mux['passed']
    m = mux['results'][0]
    assert [c['cycles'] for c in m['cases']] == [c['cycles'] for c in baseline['cases']]
    for p, h in m['source_sha256'].items():
        assert digest(Path(p)) == h
    assert digest(OUT/'response-mux/registered-owner/sim') == m['sim_sha256']
    for c in m['cases']:
        for stream in ('stdout', 'stderr'):
            assert digest(OUT/'response-mux/registered-owner'/(c['case']+'.'+stream)) == c[stream+'_sha256']
    candidate = OUT/'response-mux/registered-owner/source/rtl'
    changed = [p.name for p in (ROOT/'rtl').glob('*') if p.is_file() and digest(p) != digest(candidate/p.name)]
    assert changed == ['student_top.v']
    expected = (ROOT/'rtl/student_top.v').read_text()
    for field in ('id', 'rob_tag'):
        expected = expected.replace('assign core_d_response_'+field+' = mmio_response_valid ?',
                                    'assign core_d_response_'+field+' = lsu_mmio_inflight ?')
    assert (candidate/'student_top.v').read_text() == expected

    base_input = ROOT/'build/hum-20261014/ppa-v6/input'
    mux_input = OUT/'response-mux-ppa/input'
    for path in base_input.glob('*.v*'):
        expected = path.read_text()
        if path.name == 'student_top.v':
            for field in ('id', 'rob_tag'):
                expected = expected.replace('assign core_d_response_'+field+' = mmio_response_valid ?',
                                            'assign core_d_response_'+field+' = lsu_mmio_inflight ?')
        assert (mux_input/path.name).read_text() == expected, path

    update = read(OUT/'upstream-update.json')
    assert update['new_framework'] == '302f0cf3cccdaa5de084a2120e0d950c663e4cf5'
    for relative in ('scripts/sim.cpp', 'scripts/timing.tcl', 'scripts/ram/sram_fakeram.sv',
                     'scripts/testcase.py', 'scripts/fakeram.py'):
        assert (OUT/'framework-54fc150'/relative).read_bytes() == (OUT/'framework-302f0cf'/relative).read_bytes()
    official, mux_ppa = None, None
    for name in ('baseline', 'mux'):
        directory = OUT/('official-updated-'+name)/'opt'
        path = directory/'report.json'
        if not path.exists():
            continue
        report = read(path)
        assert report['abc_constraints'] == {'driving_cell': 'INVx1_ASAP7_75t_R', 'output_load_ff': 5.0}
        assert report['timing']['clock_period_ns'] == 2.0
        for item in report['inputs'] + report['libraries']:
            assert digest(Path(item['path'])) == item['sha256']
        script = (directory/'synth.ys').read_text()
        assert 'synth -top student_top -noabc -flatten' in script
        assert ' -constr ' in script
        for item in ('synth.ys', 'synth.log', 'abc.constr', 'constraints.sdc', 'design.json', 'mapped.v',
                     'timing.rpt', 'timing_checks.rpt', 'critical_paths.json'):
            evidence[str(directory/item)] = digest(directory/item)
        value = compact_ppa(report)
        value['abc_constraints'] = report['abc_constraints']
        value['report'] = str(path)
        value['critical_path'] = official_path(directory)
        if name == 'baseline': official = value
        else: mux_ppa = value

    base_ipc = baseline['geomean']
    cases = []
    for c in baseline['cases']:
        n = c['profile']['counts']; detail = c['detail']; cycles = c['cycles']
        cases.append({'case': c['case'], 'cycles': cycles, 'ipc': c['ipc'],
            'dynamic_instructions': c['dynamic_instructions'], 'counts': n,
            'partition_percent': {k.removeprefix('partition_'): v/cycles*100 for k, v in n.items()
                                  if k.startswith('partition_')},
            'unique_refill_lines': len(detail['refill_lines']),
            'total_refills': sum(detail['refill_lines'].values()),
            'load_latencies': detail['load_latencies'], 'store_latencies': detail['store_latencies'],
            'top_branch_errors': [{'pc': hex(int(pc)), 'wrong': wrong,
                                   'retired': detail['retired_branch_count'][pc]}
                for pc, wrong in sorted(detail['retired_branch_wrong'].items(), key=lambda x: -x[1])[:5]]})
    result = {'completed': True, 'simulation_audit_passed': True, 'head': screen['head'],
        'configuration': baseline['parameters'], 'baseline_ipc': base_ipc,
        'ipc_gain_needed_percent': (1.0985/base_ipc-1)*100,
        'original_custom_ppa': compact_ppa(ppa['report']),
        'original_fast_mapping': compact_ppa(read(ROOT/'build/hum-20261014/ppa-v6/mapping/opt/report.json')),
        'framework_update': update, 'official_ppa': official, 'response_mux_ppa': mux_ppa,
        'cases': cases, 'sensitivity': rows,
        'latency_sensitivity': [{'latency': r['latency'], 'ipc': r['geomean'],
                                'gain_percent': (r['geomean']/base_ipc-1)*100,
                                'cycles': {c['case']: c['cycles'] for c in r['cases']}}
                               for r in latency['results']],
        'probes': [{'probe': r['probe'], 'cycles': r['cycles'], 'ipc': r['ipc']} for r in probes['results']],
        'timing_paths': paths['paths'],
        'validation': {'official_performance_runs': 60+18+6, 'microbenchmarks': 5,
                       'new_full_correctness_matrix': False, 'formal_rtl_unchanged': True},
        'evidence_sha256': evidence}
    (HERE/'results-summary.json').write_text(json.dumps(result, indent=2, ensure_ascii=False)+'\n')
    print('PASS simulation and provenance audit; IPC', base_ipc,
          'official PPA', official, 'candidate PPA', mux_ppa)


if __name__ == '__main__':
    main()
