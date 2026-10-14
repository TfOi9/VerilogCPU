#!/usr/bin/env python3
"""Audit paired Cache evidence and publish the measured stage result."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path, hashes, complete=True):
    data = json.loads(path.read_text())
    assert data.get('passed') is True, path
    if complete:
        assert data.get('completed') is True, path
    assert data.get('sources_unchanged', True) is True, path
    for key in ('source_sha256', 'rtl_sha256', 'runner_sha256'):
        for name, sha in data.get(key, {}).items():
            assert digest(Path(name)) == sha, name
    hashes[str(path)] = digest(path)
    return data


def metrics(variant, ppa):
    cases = variant['cases']
    assert len(cases) == 6 and all(row['passed'] for row in cases)
    ipc = math.exp(sum(math.log(row['dynamic_instructions']/row['cycles'])
                       for row in cases)/6)
    assert math.isclose(ipc, variant['geomean'], rel_tol=1e-12)
    report = ppa['report']
    assert ppa['target_ns'] == 0.02 and ppa['history'][-1]['below_target_paths'] == 0
    assert ppa['history'][-1]['hold_violations'] == 0
    return {'ipc': ipc, 'fmax_mhz': report['timing']['estimated_fmax_mhz'],
            'area_um2': report['area']['area_um2']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, default=ROOT/'build/hum-20261014')
    parser.add_argument('--version', default='final')
    parser.add_argument('--ppa-version', default='v6')
    parser.add_argument('--unit-directory', default='hum-unit-selected')
    args = parser.parse_args()
    build = args.build.resolve()
    version = args.version
    ppa_version = args.ppa_version or version
    hashes = {}
    before = read(build/'baseline-perf/results.json', hashes)
    screen = read(build/f'screen-{version}/results.json', hashes)
    old_ppa = read(build/'ppa-baseline/results.json', hashes)
    new_ppa = read(build/f'ppa-{ppa_version}/results.json', hashes)
    matrix = read(build/f'matrix-{version}.json', hashes)
    suite = read(build/f'suite-{version}/results.json', hashes)
    unit = read(build/args.unit_directory/'results.json', hashes)
    gates = read(build/f'gates-{version}/results.json', hashes)
    negative = read(build/f'negative-{version}/results.json', hashes, False)
    probes = read(build/f'probes-{version}/results.json', hashes)
    old_probes = read(build/'probes-baseline-confirmed/results.json', hashes)
    wrap = read(build/'posted-wrap-proof/results.json', hashes)
    for row in wrap['tests']:
        assert digest(build/'posted-wrap-proof'/(row['name']+'.log')) == row['log_sha256']
        for name, sha in row['source_sha256'].items():
            assert digest(Path(name)) == sha, name
    expected_config = {'FE_WIDTH': 2, 'BE_WIDTH': 2, 'PHYS_REGS': 64,
                       'ROB_ENTRIES': 32, 'store_hints': 16,
                       'icache': [1024, 64, 1], 'dcache': [16384, 512, 2]}
    assert old_ppa['configuration'] == new_ppa['configuration'] == expected_config
    assert before['latency'] == screen['latency'] == suite['latency'] == 10
    snapshot = build/f'selected-{version}/source'
    for directory in ('rtl', 'verilog'):
        for file in (ROOT/directory).iterdir():
            if file.is_file():
                assert digest(file) == digest(snapshot/directory/file.name), file
    original_top = next(Path(name) for name in new_ppa['source_sha256']
                        if name.endswith('/source/rtl/student_top.v'))
    ppa_snapshot = original_top.parent.parent
    for file in (snapshot/'rtl').iterdir():
        if file.is_file():
            assert digest(file) == digest(ppa_snapshot/'rtl'/file.name), file
    variants = {row['variant']: row for row in screen['results']}
    assert set(variants) == {'legacy', 'bridge', 'overlap', 'hum'}
    baseline = before['results'][0]
    assert {r['case']: r['cycles'] for r in baseline['cases']} == {
        r['case']: r['cycles'] for r in variants['legacy']['cases']}
    old = metrics(baseline, old_ppa)
    new = metrics(variants['hum'], new_ppa)
    perf_suite = {row['case']: row for row in suite['results']
                  if row['case'].startswith('perf_')}
    assert len(suite['results']) == 25 and len(perf_suite) == 6
    assert math.isclose(suite['geomean'], new['ipc'], rel_tol=1e-12)
    cases = []
    for old_row, row in zip(baseline['cases'], variants['hum']['cases']):
        assert old_row['case'] == row['case']
        assert perf_suite[row['case']]['cycles'] == row['cycles']
        counts = row['profile']['counts']
        cases.append({'case': row['case'], 'baseline_cycles': old_row['cycles'],
                      'cycles': row['cycles'], 'ipc': row['ipc'],
                      'ipc_gain_percent': (old_row['cycles']/row['cycles']-1)*100,
                      'profile': row['profile']})
        assert counts['retired'] == row['dynamic_instructions']-1
    stages = Counter(row['stage'] for row in matrix['checks'])
    assert all(row['passed'] for row in matrix['checks'])
    for stage in ('iverilog-2005', 'parameter-startup', 'verilator', 'yosys'):
        assert stages[stage] == 81
    assert sum(count for stage, count in stages.items()
               if stage.startswith('retirement-')) == 27
    functional_count = sum(len(row['results']) for row in matrix['functional'])
    assert functional_count == 243
    assert len(unit['tests']) == 28 and all(row['passed'] for row in unit['tests'])
    assert len(negative['tests']) == 3 and all(row['passed'] for row in negative['tests'])
    target = {'ipc': 1.0985, 'fmax_mhz': 300.0, 'area_um2': 36000.0}
    ipc_gain = (new['ipc']/old['ipc']-1)*100
    throughput_gain = (new['ipc']*new['fmax_mhz']/(old['ipc']*old['fmax_mhz'])-1)*100
    joint = new['ipc'] >= target['ipc'] and new['fmax_mhz'] >= target['fmax_mhz'] and new['area_um2'] <= target['area_um2']
    for record, parent in ((unit, build/args.unit_directory),
                           (negative, build/f'negative-{version}'),
                           (gates, build/f'gates-{version}')):
        for row in record['tests']:
            assert digest(parent/(row['name']+'.log')) == row['log_sha256']
    for record, parent in ((before, build/'baseline-perf'),
                           (screen, build/f'screen-{version}')):
        for variant in record['results']:
            directory = parent/variant['variant']
            assert digest(directory/'sim') == variant['sim_sha256']
            for name, sha in variant['source_sha256'].items():
                assert digest(Path(name)) == sha, name
            for row in variant['cases']:
                for stream in ('stdout', 'stderr'):
                    assert digest(directory/(row['case']+'.'+stream)) == row[stream+'_sha256']
    for row in suite['results']:
        assert digest(build/f'suite-{version}'/(row['case']+'.log')) == row['log_sha256']
    for record in (old_ppa, new_ppa):
        path = Path(record['final_directory'])/'report.json'
        assert json.loads(path.read_text()) == record['report']
        hashes[str(path)] = digest(path)
    baseline_id = json.loads((build/'baseline.json').read_text())
    intermediate = []
    for stage in ('v1', 'v3', 'v4', 'v5', 'v6', 'v7'):
        path = build/f'ppa-{stage}/results.json'
        if path.exists():
            record = read(path, hashes)
            report = record['report']
            intermediate.append({'stage': stage,
                                 'fmax_mhz': report['timing']['estimated_fmax_mhz'],
                                 'area_um2': report['area']['area_um2'],
                                 'selected': stage == ppa_version,
                                 'evidence': str(path)})
    hashes[str(build/'baseline.json')] = digest(build/'baseline.json')
    hashes[str(Path(__file__).resolve())] = digest(Path(__file__).resolve())
    result = {'completed': True, 'correctness_passed': True,
              'joint_target_met': joint, 'target': target,
              'baseline_manifest': baseline_id, 'configuration': expected_config,
              'selected_snapshot': str(snapshot), 'baseline': old, 'selected': new,
              'ppa_snapshot': str(ppa_snapshot), 'ppa_rtl_identical': True,
              'intermediate_ppa': intermediate,
              'excluded_runs': ['ppa-v2 interrupted after source cleanup',
                                'matrix-v1 interrupted before ID turnaround fix',
                                'matrix-v7 and gates-v7-lint interrupted after choosing v6',
                                'hum-unit-v7 negative-test expectation corrected; rerun separately',
                                'probes-baseline used a nonexistent simulator path; rerun separately'],
              'ipc_gain_percent': ipc_gain,
              'ipc_times_fmax_gain_percent': throughput_gain,
              'remaining': {'ipc_gain_percent': (target['ipc']/new['ipc']-1)*100,
                            'frequency_gain_percent': (target['fmax_mhz']/new['fmax_mhz']-1)*100,
                            'area_headroom_um2': target['area_um2']-new['area_um2']},
              'cases': cases,
              'ablations': [{'variant': name, 'ipc': row['geomean'],
                            'parameters': row['parameters'],
                            'source_sha256': row['source_sha256'],
                            'sim_sha256': row['sim_sha256']} for name, row in variants.items()],
              'verification': {'static_configurations': 81, 'static_checks': 324,
                               'functional_runs': functional_count,
                               'retirement_differentials': 27, 'official_programs': 25,
                               'directed_cases': 28, 'contract_negative_controls': 3,
                               'make_gates': gates['tests']},
              'posted_wrap_baseline_reproduction': wrap,
              'probes_baseline': old_probes['results'], 'probes_selected': probes['results'],
              'evidence_sha256': hashes}
    dest = Path(__file__).resolve().parent/'results-summary.json'
    dest.write_text(json.dumps(result, indent=2, ensure_ascii=False)+'\n')
    by_case = {row['case']: row for row in cases}
    def share(case, counter):
        row = by_case['perf_'+case]
        return row['profile']['counts'][counter]/row['cycles']*100
    lines = [
        '# Cache 并行化优化验收（2026-10-14）', '',
        f'最终选用 v6 的 RTL：六程序 IPC 几何平均 **{new["ipc"]:.6f}**，'
        f'比本轮基线提高 **{ipc_gain:.3f}%**；最终修复后估计频率 '
        f'**{new["fmax_mhz"]:.2f} MHz**，总面积 **{new["area_um2"]:,.2f} µm²**。'
        f'IPC×估计频率提高 **{throughput_gain:.3f}%**。面积满足限制，IPC 和频率尚未达标。', '',
        '基线是本轮编辑前的本地提交 `2ec87af`，已包含上一轮驻留 Store 退休和结果早旁路。'
        '在编辑前冻结源码，并重新复现全部六项周期及同流程 PPA；本轮收益相对该基线计算。'
        '最高档要求为 1.0985 IPC、300 MHz、36,000 µm²，三项必须属于同一配置。', '',
        '固定 FE=BE=2、PRF64、ROB32、恢复宽度4、Store 提示16项、I 1 KiB单路 / '
        'D 16 KiB两路、外存10周期。RTL 默认开启并行访存，既有宽度和 Cache 容量默认值保留；'
        '本报告大 Cache 配置通过构建参数明确设置。', '',
        '| 指标 | 本轮基线 | 最终配置 |',
        '| --- | ---: | ---: |',
        f'| IPC 几何平均 | {old["ipc"]:.6f} | {new["ipc"]:.6f} |',
        f'| 最终估计频率 / MHz | {old["fmax_mhz"]:.2f} | {new["fmax_mhz"]:.2f} |',
        f'| 总面积 / µm² | {old["area_um2"]:,.2f} | {new["area_um2"]:,.2f} |', '',
        '频率沿用既有 Yosys 0.63 / ASAP7 RVT TT / FakeRAM 综合、电气修复及20 ps hold '
        '收敛流程，最终 cap、slew 和 hold 检查通过；采用无寄生、理想时钟模型，未做布局布线。'
        'IPC×估计频率用于判断降频是否抵消 IPC 收益，不是实芯片吞吐实测。', '',
        '## 改动与安全边界', '',
        '- 单项脏行写回缓冲允许写回与 refill 重叠；原 miss 等待两者错误归属完成，'
        '再安装新行。写回失败保留旧脏行。',
        '- 一个 demand miss 上下文允许其他组 hit-under-miss；缺失组锁定，'
        'SRAM 安装及重读快照时暂停流水。第二个 D miss 仍会阻塞。',
        '- 桥接器支持两个读行和一个写行，各 AXI 字通道独立推进。两个读行可属于 I/D '
        '不同客户端，不代表 D-Cache 有两个 MSHR。MMIO 等旧事务排空。',
        '- LSQ 四项请求使用独立 ID；Cache/MMIO 返回原 ROB 标签，'
        '早 Load 返回保存访问属性，保留核心的 ROB 存活和代际授权。满载同拍 ID 回收/发出避免额外空泡。',
        '- Cache 响应使用头部加 skid 槽，隔离上游反压组合路径，保持三周期无阻塞命中。', '',
        '还修复了基线中潜伏的完整标签回绕问题：延迟的已退休 posted Store 响应可能与复用槽的新 '
        'Store 标签完全相同，错误地使新 Store 可退休。退休旁路和响应回写现均排除已退休写，'
        '旧响应只排空，不能授权复用槽。定向用例在旧基线失败，在最终版本通过。', '',
        f'结构、接线及不变量见[元件文档]({ROOT}/docs/cache-hit-under-miss.md)。', '',
        '## 六程序及消融', '',
        '| 程序 | 基线周期 | 最终周期 | 最终 IPC | IPC 提升 |',
        '| --- | ---: | ---: | ---: | ---: |',
    ]
    for row in cases:
        lines.append(f'| {row["case"].removeprefix("perf_")} | '
                     f'{row["baseline_cycles"]:,} | {row["cycles"]:,} | '
                     f'{row["ipc"]:.6f} | {row["ipc_gain_percent"]:.3f}% |')
    lines += ['', '| 配置 | IPC 几何平均 | 相对基线提升 |',
              '| --- | ---: | ---: |']
    labels = {'legacy': '兼容串行通路', 'bridge': '仅桥接器并行',
              'overlap': '桥接器＋写回/refill 重叠', 'hum': '完整 hit-under-miss 组合'}
    for name, row in variants.items():
        lines.append(f'| {labels[name]} | {row["geomean"]:.6f} | '
                     f'{(row["geomean"]/old["ipc"]-1)*100:.3f}% |')
    lines += ['', '兼容模式六项周期完全复现基线。所有配置均通过架构结果检查，'
              '只有最终组合完成对应大 Cache PPA；不能把消融 IPC 与另一配置的 PPA 拼接。', '',
              '依赖链微基准的热 Load 链约0.172 IPC、热 Store 约0.509 IPC，'
              '相对本轮基线基本不变。收益主要来自缺失期间的重叠，尚未消除依赖链延迟。', '',
              '各中间版本的最终 PPA 留存如下；完整 IPC 相同的 v7 使用另一种返回缓冲数据路径，'
              '面积更小但频率更低，未采用。', '',
              '| 阶段 | 最终 MHz | 总面积 / µm² |', '| --- | ---: | ---: |']
    for row in intermediate:
        lines.append(f'| {row["stage"]}{"（选中）" if row["selected"] else ""} | '
                     f'{row["fmax_mhz"]:.2f} | {row["area_um2"]:,.2f} |')
    lines += ['', '## 验收与剩余瓶颈', '',
              '最终源码通过：`make unit`、`make lint`、`make deep-unit`；'
              '28 项并行访存定向检查（包括错误标签注入的预期拒绝）；3 项既有契约负向检查；'
              '81 组参数的324项静态检查、9组代表配置的243次程序运行与27次退休轨迹差分；'
              '选定大 Cache 配置的25项官方程序。六项官方性能周期与带计数器的仿真一致。', '',
              'v7 与较早阶段的中止/失败运行保留在原目录，未计入最终验收。最终 RTL 与 v6 '
              'PPA 输入原始快照逐字节一致，复用了该已完成 PPA；新的完整回归针对最终快照重跑。'
              '源文件、模拟器、输入、结果、日志及最终报告哈希经 `report.py` 审核。', '',
              f'距离最高档仍需 **{result["remaining"]["ipc_gain_percent"]:.2f}%** IPC 提升和 '
              f'**{result["remaining"]["frequency_gain_percent"]:.2f}%** 频率提升，'
              f'面积余量 **{result["remaining"]["area_headroom_um2"]:,.2f} µm²**。', '',
              '- 单个 demand miss 和同组锁定仍限制访存重叠；接下来应比较关键字优先返回、'
              '第二项 MSHR 和同一行请求合并，保持错误归属。',
              f'- rsort 仍有{share("rsort", "partition_head_store_response"):.2f}%的总周期等待队首 Store 响应，'
              f'vvadd 为{share("vvadd", "partition_head_store_response"):.2f}%。'
              '本轮没有减少 refill 数量，流式访问仍需预取、整行写合并或免读分配的独立证据。',
              f'- qsort 的队首 Load 等待约{share("qsort", "partition_head_load"):.2f}%、'
              f'恢复约{share("qsort", "partition_recovery"):.2f}%；'
              '依赖传递与条件分支解析仍需优化。上述类别以总周期为分母，属于无退休周期的互斥分类。',
              '- 继续约束返回广播、标签授权及请求选择组合路径；'
              '本轮没有可靠地把映射后的最长路径反查到某一 RTL 模块，不能声称已经定位最终关键路径。', '',
              f'机器可读结果：[results-summary.json]({dest})。'
              f'复现命令及证据位置：[实验说明]({dest.parent}/README.md)。'
              'SORA 未修改；所有提交仅保存在本机。', '']
    (ROOT/'docs/cache-parallel-optimization-20261014.md').write_text('\n'.join(lines))
    print('PASS evidence audit', new, 'IPC gain', ipc_gain,
          'IPC*Fmax gain', throughput_gain, 'joint target', joint)


if __name__ == '__main__':
    main()
