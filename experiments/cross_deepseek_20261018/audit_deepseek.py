#!/usr/bin/env python3
"""Audit the other branch without changing its checkout or artifacts."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/area_20261018'))
from measure import configured_sources, digest, read_sources, save


def main():
    branch = 'deepseek/area-reduction-20261018'
    original = Path('/Users/zhaoruicheng/Downloads/VerilogCPU')
    out = ROOT / 'build/cross-deepseek-20261018/deepseek-audit'
    out.mkdir(parents=True, exist_ok=False)
    revision = subprocess.check_output(['git', 'rev-parse', branch], cwd=ROOT, text=True).strip()
    paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', revision,
                                     'rtl', 'verilog'], cwd=ROOT, text=True).splitlines()
    for name in paths:
        path = out / 'source' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(subprocess.check_output(['git', 'show', revision + ':' + name], cwd=ROOT))
    configured_sources(read_sources(out / 'source/verilog/filelist.f'), (4, 2, 64, 32), out / 'input')
    wrapper = original / 'reports/synthesis-128dir.json'
    metadata = json.loads(wrapper.read_text())
    result = metadata['results'][0]
    report = result['report']
    frozen = original / 'build/synth-128dir/4x2-p64-r32/input'
    comparisons = {p.name: p.read_bytes() == (frozen / p.name).read_bytes()
                   for p in (out / 'input').glob('*.v')}
    assert comparisons and all(comparisons.values()), comparisons
    report_inputs = {Path(p['path']).name: p['sha256'] for p in report['inputs']}
    assert all(digest(frozen / name) == report_inputs[name] for name in comparisons)
    native = {k: digest(ROOT / p) for k, p in {
        'yosys': '.deps/yosys/bin/yosys', 'abc': '.deps/yosys/bin/yosys-abc',
        'opensta': '.deps/opensta/bin/sta'}.items()}
    assert all(native[k] == v['sha256'] for k, v in metadata['native_tools'].items())
    for item in report['libraries']:
        if '/asap7/lib/' in item['path']:
            assert digest(Path(item['path'])) == item['sha256']
    for name, expected in metadata['source_sha256'].items():
        if '/RISC-V-CPU-2026/scripts/' in name:
            assert digest(Path(name)) == expected
    summary = {
        'revision': revision, 'branch': branch, 'wrapper_sha256': digest(wrapper),
        'wrapper_completed': metadata['completed'], 'wrapper_passed': metadata['passed'],
        'wrapper_sources_unchanged': metadata['sources_unchanged'],
        'frozen_input_matches_committed_branch': comparisons,
        'frozen_input_matches_embedded_report_hashes': True,
        'same_native_tools_libraries_and_framework': True,
        'area_um2': report['area']['area_um2'],
        'estimated_fmax_mhz': report['timing']['estimated_fmax_mhz'],
        'minimum_period_ns': report['timing']['minimum_period_ns'],
        'area_cap_um2': 1.10 * json.loads((ROOT / 'build/area-codex-20261018/final/ppa-results.json').read_text())['report']['area']['area_um2'],
        'timing_constraints': {k: v for k, v in report['timing'].items()
                               if k not in ('critical_paths', 'paths')},
        'snapshot_sha256': digest(ROOT / 'build/cross-deepseek-20261018/fe4-d0-h8/snapshot.json'),
        'note': 'Wrapper source drift remains recorded. Frozen PPA input was independently matched to the branch; no full correctness qualification is inferred.'}
    save(out / 'results.json', summary)
    print(json.dumps({k: v for k, v in summary.items() if k not in ('timing_constraints', 'frozen_input_matches_committed_branch')}))


if __name__ == '__main__':
    main()
