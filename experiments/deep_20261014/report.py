#!/usr/bin/env python3
"""Audit the final configuration and publish the bounded optimization evidence."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'build/deep-20261014'
HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(name):
    path = OUT/name
    result = json.loads(path.read_text())
    assert result.get('passed'), name
    return result, {'path':str(path),'sha256':digest(path)}


def main():
    matrix,matrix_ref = load('matrix-final.json')
    assert matrix['completed'] and matrix['sources_unchanged']
    assert len(matrix['matrix']) == 81 and len(matrix['functional']) == 9
    for path,h in matrix['source_sha256'].items():
        assert digest(Path(path)) == h, path
    final,final_ref = load('final-selection/results.json')
    assert final['completed'] and final['sources_unchanged']
    for path,h in final['rtl_sha256'].items():
        assert digest(Path(path)) == h, path
    selected = next(x for x in final['results'] if x['variant']=='hints16')
    default = next(x for x in final['results'] if x['variant']=='default')
    suite,suite_ref = load('suite-hints16-large/results.json')
    assert suite['completed'] and suite['sources_unchanged'] and len(suite['results']) == 25
    for path,h in suite['source_sha256'].items():
        assert digest(Path(path)) == h,path
    source = OUT/'hints16-projected-source/rtl'
    assert all((source/p.name).read_bytes()==p.read_bytes() for p in (ROOT/'rtl').glob('*') if p.is_file())
    official = {x['case']:x for x in suite['results']}
    assert all(official[x['case']]['cycles']==x['cycles'] for x in selected['cases'])
    base,base_ref = load('baseline-i1/results.json');base=base['results'][0]
    original,original_ref = load('baseline-run/results.json')
    investigation = json.loads((ROOT/'experiments/bottlenecks_20261014/results-summary.json').read_text())
    for row in original['results']:
        previous = {x['case']:x['cycles'] for x in investigation['variants'][row['variant']]['cases']}
        assert all(previous[x['case']]==x['cycles'] for x in row['cases'])
    # Baseline source bytes are checked against the saved pre-edit snapshot.
    for p in (OUT/'baseline/source/rtl').glob('*'):
        if p.is_file():
            assert p.read_bytes()==(OUT/'baseline-run/big/source/rtl'/p.name).read_bytes()
    ppa,ppa_ref = load('ppa-hints16/results.json')
    paired,paired_ref = load('ppa-baseline-paired/results.json')
    assert ppa['configuration']['store_hints']==16
    for path,h in ppa['source_sha256'].items():
        assert digest(Path(path))==h,path
    checks,checks_ref = load('check-results-final.json')
    assert all(digest(Path(p))==h for p,h in checks['hardware_sha256'].items())
    units,units_ref = load('../deep-unit/results.json')
    assert units['sources_unchanged'] and len(units['tests'])==17
    assert all(digest(Path(p))==h for p,h in units['source_sha256'].items())
    negative,negative_ref = load('negative-controls/results.json')
    posted_core,posted_core_ref = load('posted-core/results.json')
    assert len(posted_core['tests'])==9
    assert all(digest(Path(p))==h for p,h in posted_core['source_sha256'].items())
    posted_retired=sum(int(re.search(r'^PASS core .* retired=(\d+)', p.read_text(),re.M)[1])
        for p in (OUT/'posted-core').glob('[124]x*-921*.log'))
    probes,probes_ref = load('probes-hints16/results.json')
    baseline_probes,baseline_probes_ref = load('probes-baseline-i1/results.json')
    candidates,candidates_ref = load('hint-scan/results.json')
    prefetch,prefetch_ref = load('prefetch-v2/results.json')
    area = ppa['report']['area']['area_um2']
    fmax = ppa['report']['timing']['estimated_fmax_mhz']
    baseline_fmax = paired['report']['timing']['estimated_fmax_mhz']
    cases = []
    old = {x['case']:x for x in base['cases']}
    for c in selected['cases']:
        b=old[c['case']]
        cases.append({'case':c['case'],'baseline_cycles':b['cycles'],'final_cycles':c['cycles'],
                      'baseline_ipc':b['ipc'],'final_ipc':c['ipc'],
                      'ipc_gain_percent':100*(c['ipc']/b['ipc']-1)})
    report = {'completed':True,'passed':True,'scope':'validated optimization; joint target remains unmet',
        'configuration':selected['parameters'],'hardware_sha256':checks['hardware_sha256'],
        'baseline_ipc_geomean':base['geomean'],'ipc_geomean':selected['geomean'],
        'default_cache_ipc_geomean':default['geomean'],
        'ipc_gain_percent':100*(selected['geomean']/base['geomean']-1),
        'frequency_weighted_gain_percent':100*(selected['geomean']*fmax/(base['geomean']*baseline_fmax)-1),
        'area_um2':area,'estimated_fmax_mhz':fmax,
        'baseline_area_um2':paired['report']['area']['area_um2'],'baseline_fmax_mhz':baseline_fmax,
        'remaining_ipc_gain_percent':100*(1.0985/selected['geomean']-1),
        'joint_target_passed':selected['geomean']>1.0985 and area<=36000 and fmax>=300,
        'matrix':{'configurations':81,'static_checks':324,'retirement_traces':27,
                  'program_runs':sum(len(x['results']) for x in matrix['functional'])},
        'posted_core':{'traces':9,'retired':posted_retired,'memory_model':posted_core['scope']},
        'baseline_runs_reproduced':12,
        'cases':cases,'probes':probes['results'],'baseline_probes':baseline_probes['results'],
        'evidence':[matrix_ref,final_ref,suite_ref,base_ref,original_ref,ppa_ref,paired_ref,
                    checks_ref,units_ref,negative_ref,posted_core_ref,probes_ref,baseline_probes_ref,candidates_ref,prefetch_ref],
        'rejected_prefetch':{'geomean':prefetch['results'][0]['geomean'],
                            'reason':'mean regression and extra D read traffic; not integrated'},
        'limitations':['blocking demand D-cache','no general speculative store preparation or MSHRs',
                       'PPA is TT without routed parasitics or CTS','IPC and frequency targets remain unmet']}
    (HERE/'results-summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print('PASS audited final evidence IPC={} area={} Fmax={} joint_target={}'.format(
        report['ipc_geomean'],area,fmax,report['joint_target_passed']))


if __name__ == '__main__':
    main()
