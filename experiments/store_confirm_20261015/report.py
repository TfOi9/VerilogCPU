#!/usr/bin/env python3
"""Validate immutable measurements and summarize the completed work package."""
import argparse
import hashlib
import json
import math
from pathlib import Path
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

    def measure(directory):
        snapshot = read(directory/'snapshot.json')
        guard(snapshot['source_sha256'])
        sim = read(directory/'sim-results.json')
        ppa = read(directory/'ppa-results.json')
        assert all(r['completed'] and r['passed'] for r in (sim, ppa))
        assert all(r['snapshot_sha256'] == digest(directory/'snapshot.json') for r in (sim, ppa))
        assert digest(directory/'official/sim') == sim['sim_sha256']
        assert len(sim['cases']) == 25 and len({c['name'] for c in sim['cases']}) == 25
        cases = []
        for row in sim['cases']:
            assert digest(directory/(row['name']+'.log')) == row['log_sha256']
            case = ROOT.parent/'RISC-V-CPU-2026-Testcases'/row['name']
            for name, key in (('program.data', 'image_sha256'), ('expected.txt', 'expected_sha256')):
                assert digest(case/name) == row[key]
            if row['name'].startswith('perf_'):
                assert digest(case/'metrics.json') == row['metrics_sha256']
                assert math.isclose(row['ipc'], row['dynamic_instructions']/row['cycles'], rel_tol=1e-12)
                cases.append(row)
        assert len(cases) == 6
        assert math.isclose(sim['ipc_geomean'], math.exp(sum(math.log(c['ipc']) for c in cases)/6), rel_tol=1e-12)
        guard(ppa['artifact_sha256'])
        r = ppa['report']
        validate_report(r, 'opt', 2.0)
        assert r['tools']['yosys'].startswith('Yosys 0.63 ')
        for item in r['inputs']+r['libraries']:
            assert digest(Path(item['path'])) == item['sha256'], item['path']
        assert r == read(directory/'ppa/opt/report.json')
        assert r['abc_constraints'] == {'driving_cell': 'INVx1_ASAP7_75t_R', 'output_load_ff': 5.0}
        return {'ipc_geomean': sim['ipc_geomean'], 'area_um2': r['area']['area_um2'],
                'fmax_mhz': r['timing']['estimated_fmax_mhz'],
                'minimum_period_ns': r['timing']['minimum_period_ns'],
                'critical_path': official_path(directory/'ppa/opt'), 'cases': cases}

    original = ROOT/'build/store-directory-20261015/selected'
    stages = {'baseline256': measure(original),
              'baseline64': measure(out/'baseline64'),
              'baseline128': measure(out/'baseline128'),
              'selected128': measure(out/'final128')}
    for p in (out/'baseline64/source/rtl').iterdir():
        if p.is_file():
            assert p.read_bytes() == (original/'source/rtl'/p.name).read_bytes(), p
    for p in (ROOT/'rtl').iterdir():
        if p.is_file():
            assert p.read_bytes() == (out/'final128/source/rtl'/p.name).read_bytes(), p

    profile = read(out/'profile-final/results.json')
    audit = read(out/'profile-final/input-audit.json')
    assert profile['completed'] and profile['passed'] and audit['unchanged']
    guard(audit['input_sha256'])
    guard(profile['rtl_sha256'])
    guard(profile['runner_sha256'])
    assert len(profile['results']) == 1
    selected_profile = profile['results'][0]
    assert all(selected_profile['parameters'][k] == n for k, n in {
        'FE_WIDTH': 2, 'BE_WIDTH': 2, 'PHYS_REGS': 64, 'ROB_ENTRIES': 32,
        'STORE_DIRECTORY_ENTRIES': 128, 'LATE_STORE_CONFIRM': 1,
        'ICACHE_SIZE_BYTES': 1024, 'DCACHE_SIZE_BYTES': 16384}.items())
    guard(selected_profile['source_sha256'])
    assert digest(out/'profile-final/dir128-late1/sim') == selected_profile['sim_sha256']
    final_cases = {c['name']: c for c in stages['selected128']['cases']}
    for c in selected_profile['cases']:
        for suffix in ('stdout', 'stderr'):
            assert digest(out/'profile-final/dir128-late1'/(c['case']+'.'+suffix)) == c[suffix+'_sha256']
        assert c['cycles'] == final_cases[c['case']]['cycles']
        assert c['profile']['counts']['retired'] == c['dynamic_instructions']-1

    screen = read(out/'screen-v2/results.json')
    audit = read(out/'screen-v2/input-audit.json')
    assert screen['completed'] and screen['passed'] and audit['unchanged']
    guard(audit['input_sha256'])
    guard(screen['rtl_sha256'])
    guard(screen['runner_sha256'])
    sensitivity = {}
    for r in screen['results']:
        guard(r['source_sha256'])
        assert digest(out/'screen-v2'/r['variant']/'sim') == r['sim_sha256']
        sensitivity[r['variant']] = {'ipc_geomean': r['geomean'],
            'cycles': {c['case']: c['cycles'] for c in r['cases']}}
    assert sensitivity['dir128-late1']['cycles'] == {k: c['cycles'] for k, c in final_cases.items()}

    control = read(out/'profile-control/results.json')
    control_audit = read(out/'profile-control/input-audit.json')
    assert control['completed'] and control['passed'] and control_audit['unchanged']
    guard(control['rtl_sha256'])
    guard(control['runner_sha256'])
    guard(control_audit['input_sha256'])
    assert len(control['results']) == 1
    control_row = control['results'][0]
    guard(control_row['source_sha256'])
    assert control_row['parameters']['STORE_DIRECTORY_ENTRIES'] == 128
    assert control_row['parameters']['LATE_STORE_CONFIRM'] == 0
    assert digest(out/'profile-control/dir128-late0/sim') == control_row['sim_sha256']
    assert {c['case']: c['cycles'] for c in control_row['cases']} == sensitivity['dir128-late0']['cycles']

    gates = read(out/'gates-final/results.json')
    assert gates['completed'] and gates['passed']
    guard(gates['source_sha256'])
    for row in gates['tests']:
        assert row['exit_code'] == 0 and digest(Path(row['log'])) == row['log_sha256']
    confirm = read(out/'store-confirm-final/results.json')
    assert confirm['completed'] and confirm['passed'] and len(confirm['tests']) == 64
    guard(confirm['source_sha256'])
    directory = read(out/'gates-final/directory/results.json')
    hum = read(out/'gates-final/hum/results.json')
    owners = read(out/'gates-final/response-owner/results.json')
    assert directory['passed'] and hum['passed'] and owners['passed']
    for r in (directory, hum, owners):
        guard(r['source_sha256'])
    matrix = read(out/'matrix-final.json')
    assert matrix['completed'] and matrix['passed'] and matrix['sources_unchanged']
    guard(matrix['source_sha256'])
    assert all(c['passed'] and c['returncode'] == 0 for c in matrix['checks'])
    for c in matrix['checks']:
        log = Path(c['log']).resolve()
        evidence[str(log)] = digest(log)
    assert len([c for c in matrix['checks'] if c['stage'] in ('iverilog-2005', 'parameter-startup', 'verilator', 'yosys')]) == 324
    assert len(matrix['functional']) == 9
    assert sum(c['stage'].startswith('retirement-') for c in matrix['checks']) == 27
    assert all(r['passed'] for r in matrix['functional'])
    sys.path.insert(0, str(ROOT.parent/'RISC-V-CPU-2026/scripts'))
    from build import read_sources
    sources = read_sources(ROOT/'verilog/filelist.f')
    headers = sorted({h for p in sources for h in p.parent.glob('*.vh')})
    aggregate = hashlib.sha256()
    for p in sources+headers:
        aggregate.update(p.name.encode()+b'\0'+p.read_bytes())
    for r in matrix['functional']:
        assert r['rtl_sha256'] == aggregate.hexdigest()
        assert all(c['passed'] for c in r['results'])
        for c in r['results']:
            log = Path(c['log']).resolve()
            evidence[str(log)] = digest(log)
    probes = read(out/'probes-final/results.json')
    assert probes['completed'] and probes['passed'] and len(probes['results']) == 12
    guard(probes['input_sha256'])
    for r in probes['results']:
        log = out/'probes-final'/('store-ring-'+str(r['lines'])+'-'+r['stage']+'.log')
        assert digest(log) == r['log_sha256']
        assert digest(out/'probes-final'/('store-ring-'+str(r['lines'])+'.data')) == r['image_sha256']
    negative = read(out/'negative-control/results.json')
    assert negative['passed'] and all(r['exit_code'] == 1 for r in negative['tests'])
    guard(negative['source_sha256'])

    latency = read(out/'return-latency/results.json')
    assert latency['completed'] and latency['passed'] and len(latency['tests']) == 8
    guard(latency['source_sha256'])
    assert all(r['passed'] for r in latency['tests'])

    trace = read(out/'path-trace/results.json')
    assert trace['completed'] and trace['passed']
    guard(trace['official_sha256'])
    guard(trace['source_sha256'])
    assert 'dcache.r_id[1]' in trace['paths'][0]['start']['rtl_state']
    assert trace['paths'][0]['end']['rtl_state'] == ['core.lsq.address[4][8]']

    before, after = stages['baseline256'], stages['selected128']
    assert after['area_um2'] <= 36000 and after['fmax_mhz'] >= 300
    assert after['area_um2'] < before['area_um2']
    assert after['ipc_geomean']/after['area_um2'] > before['ipc_geomean']/before['area_um2']
    changes = {k: (after[k]/before[k]-1)*100 for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')}
    rows = []
    for c in selected_profile['cases']:
        name = c['case']
        baseline = next(r for r in before['cases'] if r['name'] == name)
        counts = c['profile']['counts']
        rows.append({'case': name, 'baseline256_cycles': baseline['cycles'],
            'selected128_cycles': c['cycles'], 'ipc_change_percent': (baseline['cycles']/c['cycles']-1)*100,
            'early_proof_stores': counts.get('detail_posted_ram_stores', 0),
            'late_confirmations': counts.get('detail_late_confirmations', 0),
            'retired_on_confirmation': counts.get('detail_retired_on_confirmation', 0)})
    result = {'completed': True, 'passed': True, 'baseline_revision': '85867e4',
        'selected_configuration': read(out/'final128/snapshot.json')['configuration'],
        'stages': stages, 'sensitivity_ipc_only': sensitivity,
        'final_source_confirmation_control': {'ipc_geomean': control_row['geomean'],
            'cycles': {c['case']: c['cycles'] for c in control_row['cases']}},
        'change_percent': changes,
        'estimated_throughput_change_percent': ((after['ipc_geomean']*after['fmax_mhz'])/
            (before['ipc_geomean']*before['fmax_mhz'])-1)*100,
        'ipc_per_area_change_percent': ((after['ipc_geomean']/after['area_um2'])/
            (before['ipc_geomean']/before['area_um2'])-1)*100,
        'metadata_bits': {'before': 10752, 'after': 5632}, 'cases': rows,
        'selected_critical_path_state': trace['paths'][0],
        'joint_tier_three_target_met': after['ipc_geomean'] >= 1.0985 and after['area_um2'] <= 36000 and after['fmax_mhz'] >= 300,
        'validation': {'official_programs_per_measured_version': 25,
            'confirmation_configurations': len(confirm['tests']),
            'confirmation_response_checks': sum(r.get('checks', 0) for r in confirm['tests']),
            'checked_confirmations': sum(r.get('confirmations', 0) for r in confirm['tests']),
            'response_owner_checks': sum(r['checks'] for r in owners['tests']),
            'aux_return_latency_configurations': 8,
            'aux_return_latency_response_checks': sum(r['checks'] for r in latency['tests']),
            'matrix_static_checks': 324, 'matrix_representatives': 9,
            'retirement_traces': 27, 'matrix_program_runs': sum(len(r['results']) for r in matrix['functional'])},
        'probes': probes['results'], 'evidence_sha256': evidence}
    evidence[str(Path(__file__))] = digest(Path(__file__))
    (HERE/'results-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    lines = ["# 小目录与后续确认验收（2026-10-15）", "",
        f"本轮采用 FE2/BE2、128 项 Store 目录与真实 tag 命中后的后续确认，并将 RAM/MMIO 返回选择前移至原返回寄存器之前。相对 `85867e4` 的 256 项目录，面积由 {before['area_um2']:,.2f} 降至 {after['area_um2']:,.2f} µm²（{changes['area_um2']:+.2f}%），估计频率由 {before['fmax_mhz']:.2f} 变为 {after['fmax_mhz']:.2f} MHz（{changes['fmax_mhz']:+.2f}%）。六程序 IPC 几何平均为 {after['ipc_geomean']:.6f}（{changes['ipc_geomean']:+.3f}%）。", "",
        f"IPC×估计频率变化 {result['estimated_throughput_change_percent']:+.2f}%，IPC/面积变化 {result['ipc_per_area_change_percent']:+.2f}%。目录元数据由 10,752 位降为 5,632 位，减少 47.62%。最高档要求同一配置 IPC≥1.0985、面积≤36,000 µm²、频率≥300 MHz，本轮仍未达到联合门槛。", "",
        "## 独立 PPA 对照", "",
        "所有表中配置均分别跑完 25 项官方程序和原版官方 PPA；不能拼接不同配置的 IPC 与频率。同容量旧 128 项与新 128 项的对照中，新方案的 IPC 提高约 0.466%、面积降低约 0.439%、估计频率提高约 0.339%，IPC×估计频率提高约 0.807%。", "",
        "| 配置 | 六项 IPC 几何平均 | 面积 µm² | 估计频率 MHz |", "| --- | ---: | ---: | ---: |"]
    for key, label in [('baseline256', '旧 256 项'), ('baseline64', '旧 64 项'),
                       ('baseline128', '旧 128 项'), ('selected128', '新 128 项＋后续确认')]:
        r = stages[key]
        lines.append(f"| {label} | {r['ipc_geomean']:.6f} | {r['area_um2']:,.2f} | {r['fmax_mhz']:.2f} |")
    lines += ["", "## 程序与机制", "",
        "| 程序 | 旧 256 项周期 | 新 128 项周期 | IPC 变化 | 后续确认直接退休 Store |", "| --- | ---: | ---: | ---: | ---: |"]
    for r in rows:
        lines.append(f"| {r['case'].removeprefix('perf_')} | {r['baseline256_cycles']:,} | {r['selected128_cycles']:,} | {r['ipc_change_percent']:+.3f}% | {r['retired_on_confirmation']:,} |")
    lines += ["", "rsort 的 5,297 笔 Store 由真实 tag 命中后的后续确认提前退休。同容量、相同返回结构下，关闭确认需要 194,099 周期，开启后为 188,739 周期，减少 5,360 周期；qsort 在这一同容量对照中反而增加 22 周期，已保留该回退。vvadd 周期不变，确认没有解决真实 miss 的串行化。", "",
        "256 项加后续确认的 IPC 为 0.733299，仅完成周期筛选，没有最终 PPA；新 64 项＋后续确认候选亦未完成最终源码全部验收，均不作为选定配置。通用 Store 环在 32/96 行时周期不变；160 行时，新 128 项加确认从关闭确认的 55,636 周期降至 49,306 周期，但仍慢于旧 256 项的 36,542 周期。小目录覆盖损失并未消失。", "",
        "## 时序与保证", "",
        "顶层不再包含 `lsu_mmio_inflight` 控制的返回后选择器。RAM 和 MMIO 身份、有效性与错误在返回寄存器之前仲裁，寄存后的统一返回直连 LSQ。普通 RAM Load 无阻塞命中仍为三周期，快速返回与写回旁路保留。MMIO 响应增加一个寄存阶段；实际外部写协议不变。", "",
        "确认携带请求 ID 和完整 ROB tag，并通过 pending 中保存的完整 LSQ tag 核对当前队首。重复确认、已退休事务、discard、恢复与 MMIO 均不能授权新 Store；确认后的写由 Cache 持有并跨回滚/flush 完成。miss 的脏写回/refill 错误仍通过正常响应精确归属。内部结构、逻辑与接线见[设计文档](late-store-confirmation.md)。", "",
        "## 验收与复现", "",
        f"最终源码通过 make unit、make lint、64 组后续确认检查（{result['validation']['confirmation_response_checks']:,} 次响应核对、{result['validation']['checked_confirmations']:,} 次确认核对）、71 组原目录检查、28 组 HUM、{result['validation']['response_owner_checks']:,} 次返回边界核对；完整 81 组参数矩阵完成 324 项静态检查、27 条逐退休差分轨迹和 {result['validation']['matrix_program_runs']} 次程序运行。精确选定配置的 25 项官方程序通过，正式/观测六项周期一致。额外 8 组启用辅助返回入口、辅助输入空闲的 Cache 测试核对了三周期无阻塞命中；共完成 3,428 次响应核对。两份故意破坏副本均被对应所有权/集成检查拒绝。", "",
        "官方 PPA 使用未修改的课程脚本、Yosys 0.63、OpenSTA、ASAP7、FakeRAM、2 ns 时钟及默认 ABC 驱动/5 fF 负载。估计频率基于理想时钟与无布线寄生；2 ns 目标的 setup slack 仍为负，不能称为 500 MHz 或物理签核。最长路径由 92 级组合逻辑变为 88 级，到达时间由 3.084 ns 变为 3.113 ns，级数减少没有转换成最高频率收益。官方网表中未保留足够来源属性的状态位，通过独立的 pre-ABC 诊断重放关联；原 PPA 产物保持不变。当前最差路径由 `dcache.r_id[1]` 到 `core.lsq.address[4][8]`，到达时间为 3.113 ns；返回身份到 LSQ 地址状态之间的组合链仍是后续约束对象。关联的具体状态记录在机器可读汇总中。", "",
        "冻结源码、命令、原始日志、工具/输入/产物 SHA256 和失败记录在 `build/store-confirm-20261015/`；早期 lint timeout、位宽警告、失效源码验证和参考程序初稿失败均保留。复现入口见[实验说明](../experiments/store_confirm_20261015/README.md)，机器可读结果见[汇总](../experiments/store_confirm_20261015/results-summary.json)。本轮没有修改 SORA，也没有包含既有未提交计划文件。", "",
        "后续按原优先级继续检查返回到整数 RS 的剩余路径，再评估 2 项 MSHR 与同一行合并、桥接事务关联和错误仲裁；qsort 的恢复接收与 BP 扩表尚未实施。", ""]
    (ROOT/'docs/store-confirm-optimization-20261015.md').write_text('\n'.join(lines))
    print(json.dumps({'change_percent': changes, 'selected': {k: after[k] for k in
        ('ipc_geomean', 'area_um2', 'fmax_mhz')}, 'validation': result['validation']}, indent=2))


if __name__ == '__main__':
    main()
