"""Audit complete gates and bind the measured executable and PPA to one RTL tree."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, required=True)
p.add_argument('--gates', type=Path, required=True)
p.add_argument('--run', type=Path, required=True)
p.add_argument('--ppa', type=Path, required=True)
p.add_argument('--matrix', type=Path, required=True)
p.add_argument('--retirement', type=Path, required=True)
p.add_argument('--package', type=Path, required=True)
p.add_argument('--runtime', type=Path, required=True)
p.add_argument('--amd64-package', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
read = lambda p: json.loads(p.read_text())
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
def passed(path):
    x = read(path)
    assert x.get('completed') is True and x.get('passed') is True, path
    if 'sources_unchanged' in x: assert x['sources_unchanged'], path
    if 'returncode' in x: assert x['returncode'] == 0, path
    return x
sys.path.insert(0,str(a.source/'tools'))
from run_synthesis import validate_report
gate_files = [a.gates/(n+'.exit.json') for n in ('strict-lint','unit-hum','suite','retirement','raw-ppa','matrix')]
for f in gate_files:
    gate = passed(f)
    assert all(digest(Path(name)) == expected for name, expected in gate['source_sha256'].items()), f
    assert digest(f.with_name(f.name.replace('.exit.json', '.log'))) == gate['log_sha256'], f
suite = passed(a.run/'suite-results.json')
matrix = passed(a.matrix)
retirement = passed(a.retirement/'results.json')
runtime = passed(a.runtime/'results.json')
ppa = read(a.ppa/'opt/report.json')
validate_report(ppa, 'opt', 2.0)
for item in ppa['inputs'] + ppa['libraries']: assert digest(Path(item['path'])) == item['sha256'], item['path']
for directory in ('rtl','verilog'):
    for src in (a.source/directory).rglob('*'):
        if not src.is_file(): continue
        relative = src.relative_to(a.source)
        for tree in (a.run/'source', a.package, a.amd64_package):
            assert digest(src) == digest(tree/relative), (src, tree)
for tree in (a.package,a.amd64_package):
    passed(tree.parent/(tree.name+'-build/results.json'))
    assert digest(a.source/'Makefile') == digest(tree/'Makefile')
assert runtime['code_sha256'] == digest(a.package/'code')
assert all(digest(a.package/n)==h and digest(a.source/n)==h for n,h in runtime['source_sha256'].items())
vendor = a.source/'third_party/cpu2026'
manifest = read(vendor/'upstream-manifest.json')
assert manifest['upstream_commit'] == '302f0cf3cccdaa5de084a2120e0d950c663e4cf5'
assert len(manifest['files_sha256']) == 17
assert all(digest(vendor/n)==h for n,h in manifest['files_sha256'].items())
assert len(suite['cases']) == len(runtime['cases']) == 25
assert {x['name']:x['cycles'] for x in suite['cases']} == {x['name']:x['cycles'] for x in runtime['cases']}
assert suite['ipc_geomean'] == runtime['ipc_geomean']
assert all(x['passed'] for x in matrix['checks'])
assert len(matrix['checks']) == 381 and len(matrix['functional']) == 9
assert all(x['completed'] and x['passed'] for x in matrix['functional'])
assert len(retirement['tests']) == 6
metrics = dict(ipc_geomean=suite['ipc_geomean'], area_um2=ppa['area']['area_um2'], fmax_mhz=ppa['timing']['estimated_fmax_mhz'])
thresholds = metrics['ipc_geomean'] >= 1.0985 and metrics['area_um2'] <= 36000 and metrics['fmax_mhz'] >= 300
assert thresholds, metrics
assert max(x['maximum_rss_bytes'] for x in runtime['cases']) <= 320*1024*1024
assert runtime['filesystem_read_only'] and runtime['file_size_limit_bytes'] == 0 and runtime['trace_enabled']
result = dict(completed=True, local_qualification_passed=True, score_thresholds_passed=True,
              actual_oj_submission_performed=False, actual_per_case_oj_time_limits_verified=False,
              metrics=metrics, matrix_checks=381, matrix_program_runs=sum(len(x['results']) for x in matrix['functional']),
              selected_retirement_traces=6, official_cases=25, linux_cases=25,
              linux_platform=runtime['platform'], tested_per_case_seconds=runtime['per_case_seconds'],
              maximum_rss_bytes=max(x['maximum_rss_bytes'] for x in runtime['cases']),
              code_sha256=runtime['code_sha256'], source_sha256=runtime['source_sha256'],
              evidence_sha256={str(f):digest(f) for f in gate_files+[a.run/'suite-results.json',a.matrix,a.retirement/'results.json',a.runtime/'results.json',a.ppa/'opt/report.json']})
a.out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ('local_qualification_passed','metrics','matrix_checks','matrix_program_runs','maximum_rss_bytes')}))
