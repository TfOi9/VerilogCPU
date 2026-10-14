#!/usr/bin/env python3
"""Compare both qualified steps, frozen profiles and official PPA evidence."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT/'build/load-path-20261014'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    evidence = {}

    def read(path):
        evidence[str(path)] = digest(path)
        return json.loads(path.read_text())

    stages = {name: read(HERE/(name+'-results.json')) for name in ('owner', 'load')}
    for stage in stages.values():
        assert stage['completed'] and stage['passed']
        for item in stage['preserved_inputs']:
            assert digest(Path(item['frozen'])) == item['sha256'], item['frozen']
        for path, sha in stage['evidence_sha256'].items():
            assert digest(Path(path)) == sha, path
    for path in (ROOT/'rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (OUT/'load-precomputed/source/rtl'/path.name).read_bytes()

    baseline = read(ROOT/'experiments/tier3_20261014/results-summary.json')
    base_report = read(Path(baseline['official_ppa']['report']))
    for item in base_report['inputs']+base_report['libraries']:
        assert digest(Path(item['path'])) == item['sha256']
    assert (ROOT.parent/'RISC-V-CPU-2026/scripts/synth.py').read_bytes() == (
        ROOT/'build/tier3-20261014/framework-302f0cf/scripts/synth.py').read_bytes()
    old_cycles = {c['case']: c['cycles'] for c in baseline['cases']}
    owner_cycles = {c['name']: c['cycles'] for c in stages['owner']['cases'] if 'ipc' in c}
    assert old_cycles == owner_cycles
    screens = {}
    for name in ('older', 'any', 'precomputed'):
        directory = OUT/('load-'+name+'-screen')
        record = read(directory/'results.json')
        assert record['completed'] and record['passed'] and record['sources_unchanged']
        row = record['results'][0]
        for path, sha in row['source_sha256'].items():
            assert digest(Path(path)) == sha
        assert digest(directory/'i1-d16/sim') == row['sim_sha256']
        for case in row['cases']:
            for stream in ('stdout', 'stderr'):
                assert digest(directory/'i1-d16'/(case['case']+'.'+stream)) == case[stream+'_sha256']
        screens[name] = {'ipc_geomean': row['geomean'],
                         'cycles': {c['case']: c['cycles'] for c in row['cases']}}
    final_cycles = {c['name']: c['cycles'] for c in stages['load']['cases'] if 'ipc' in c}
    assert final_cycles == screens['precomputed']['cycles'] == screens['older']['cycles']
    for name in ('older', 'precomputed'):
        record = read(OUT/('load-'+name)/'ppa-results.json')
        assert record['completed'] and record['passed']
        for path, sha in record['artifact_sha256'].items():
            assert digest(Path(path)) == sha
        screens[name].update(area_um2=record['report']['area']['area_um2'],
                             fmax_mhz=record['report']['timing']['estimated_fmax_mhz'])
    probes = {}
    for name in ('owner', 'load'):
        directory = OUT/(name+'-probes')
        record = read(directory/'results.json')
        assert record['completed'] and record['passed']
        assert len(record['results']) == 5
        for row in record['results']:
            assert digest(directory/(row['probe']+'.data')) == row['image_sha256']
            evidence[str(directory/(row['probe']+'.log'))] = digest(directory/(row['probe']+'.log'))
        probes[name] = [{'probe': r['probe'], 'cycles': r['cycles'], 'ipc': r['ipc']}
                        for r in record['results']]
    baseline_profile = read(ROOT/'build/tier3-20261014/response-mux/results.json')['results'][0]
    assert read(OUT/'owner-probes/results.json')['sim_sha256'] == baseline_profile['sim_sha256']
    assert read(OUT/'load-probes/results.json')['sim_sha256'] == read(
        OUT/'load-precomputed-screen/results.json')['results'][0]['sim_sha256']
    for path in (OUT/'owner/source/rtl').glob('*'):
        if path.is_file():
            assert path.read_bytes() == (ROOT/'build/tier3-20261014/response-mux/registered-owner/source/rtl'/path.name).read_bytes()
    before, after = stages['owner'], stages['load']
    assert after['ipc_geomean'] > before['ipc_geomean']
    assert after['fmax_mhz'] > before['fmax_mhz']
    assert [c['name'] for c in before['cases']] == [c['name'] for c in after['cases']]
    for a, b in zip(before['cases'], after['cases']):
        for field in ('image_sha256', 'expected_sha256', 'metrics_sha256'):
            assert a.get(field) == b.get(field)
    owner_snapshot = read(OUT/'owner/snapshot.json')
    load_snapshot = read(OUT/'load-precomputed/snapshot.json')
    assert owner_snapshot['configuration'] == load_snapshot['configuration']
    changed = [p.name for p in (OUT/'owner/source/rtl').glob('*') if p.is_file() and
               p.read_bytes() != (OUT/'load-precomputed/source/rtl'/p.name).read_bytes()]
    assert changed == ['rv32_load_store_queue.v']
    assert [r['probe'] for r in probes['owner']] == [r['probe'] for r in probes['load']]
    targeted = read(OUT/'load-address-unit-results.json')
    assert len(targeted) == 6 and all(r['passed'] for r in targeted)
    assert (OUT/'load-address-tb.v').read_bytes() == (ROOT/'tb/rv32_load_store_queue_tb.v').read_bytes()
    for row in targeted:
        log = OUT/(row['variant']+'-unit-'+str(row['width'])+'-run.log')
        assert digest(log) == row['log_sha256']
        evidence[str(log)] = digest(log)
        if row['expected_failure']:
            assert 'load skips address bubble' in log.read_text()
    result = {'completed': True, 'passed': True, 'framework_revision': after['framework_revision'],
        'baseline': {'ipc_geomean': baseline['baseline_ipc'], **baseline['official_ppa']},
        'stages': {n: {k: s[k] for k in ('ipc_geomean', 'area_um2', 'fmax_mhz', 'validation')}
                   for n, s in stages.items()},
        'load_change_percent': {k: (after[k]/before[k]-1)*100
                               for k in ('ipc_geomean', 'area_um2', 'fmax_mhz')},
        'ipc_gain_remaining_percent': (1.0985/after['ipc_geomean']-1)*100,
        'screened_candidates': screens, 'probes': probes,
        'qualification': 'Both steps qualified; IPC tier-three target remains unmet',
        'evidence_sha256': evidence}
    (HERE/'results-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    cases = '\n'.join('| {} | {:,} | {:,} | {:+.2f}% |'.format(
        name.removeprefix('perf_'), owner_cycles[name], cycles,
        (cycles/owner_cycles[name]-1)*100) for name, cycles in final_cycles.items())
    probe_rows = '\n'.join('| {} | {:,} | {:,} | {:.6f} → {:.6f} |'.format(
        a['probe'], a['cycles'], b['cycles'], a['ipc'], b['ipc'])
        for a, b in zip(probes['owner'], probes['load']))
    text = f'''# 返回标签与Load依赖路径优化验收

两步实现均已完成完整回归。返回标签统一使用注册所有权；Load路径在没有较老Store时，将地址接收与请求寄存合并到同一边沿。最终六程序IPC为 **{after['ipc_geomean']:.6f}**，面积 **{after['area_um2']:,.2f} µm²**，官方估计频率 **{after['fmax_mhz']:.2f} MHz**。相对第一步，IPC提升0.69%、面积增加0.25%、频率提升3.39%；最高基础档IPC目标仍需提升 **{result['ipc_gain_remaining_percent']:.2f}%**。

## 同配置最新官方结果

固定FE2/BE2、PRF64、ROB32、恢复4、LSQ8、Store提示16、I1 KiB单路、D16 KiB两路、外存10周期。官方框架重新fetch确认仍为`302f0cf3cccdaa5de084a2120e0d950c663e4cf5`，直接执行其原始综合脚本及默认ABC驱动/负载，使用Yosys0.63、OpenSTA3.1.0。没有采用FAST_SYNTH或定制网表修复。

| 同配置版本 | IPC几何平均 | 总面积 µm² | 估计频率 MHz |
| --- | ---: | ---: | ---: |
| 调查基线 | {baseline['baseline_ipc']:.6f} | {base_report['area']['area_um2']:,.2f} | {base_report['timing']['estimated_fmax_mhz']:.2f} |
| 第一步：返回标签所有权 | {before['ipc_geomean']:.6f} | {before['area_um2']:,.2f} | {before['fmax_mhz']:.2f} |
| 第二步：Load地址接收捷径 | {after['ipc_geomean']:.6f} | {after['area_um2']:,.2f} | {after['fmax_mhz']:.2f} |
| 最高基础档门槛 | ≥1.098500 | ≤36,000 | ≥300 |

调查基线复用上一轮同版本官方结果，并重新核对输入、脚本与库哈希。第一步本轮重新测量，逐值复现此前候选结果；第二步采用与最终RTL逐字节一致的冻结副本测量。候选预研仅发生在隔离副本，正式RTL按返回标签验证提交、Load改动的顺序推进。

## 第一步：返回身份由注册所有权选择

正式RTL只有`student_top.v`两处mux条件变化，ROB tag和在途ID与valid/data/error使用相同的`lsu_mmio_inflight`。六项周期逐项不变，面积降低0.51%、频率提升3.16%。结构和完整资格证据分别见[返回所有权](response-ownership.md)和[第一步验收](return-tag-validation-20261014.md)。

## 第二步：删除地址数组到请求选择的一拍

LSQ按槽位并行计算`no_older_store`，输入只来自已注册的busy、类型和ROB年龄。收到地址时，完整ROB/LSQ标签、AGU握手与地址合法性检查通过后，查询对应槽位；在请求寄存器可接收且没有优先候选、没有MMIO隔离时，直接保存地址和完整身份，并标记该Load已启动。

请求寄存器仍保留，因此反压稳定性与在途ID分配规则不变。存在任何较老Store时仍走原有路径，即使它已知不重叠也不走捷径；逐字节转发、部分覆盖等待、错误响应、符号扩展和精确异常逻辑没有改动。Cache RTL没有修改，三周期命中契约保持。接线和时序说明见[LSQ设计](lsq.md)。

| 官方性能程序 | 第一步周期 | 第二步周期 | 周期变化 |
| --- | ---: | ---: | ---: |
{cases}

五个通用微基准重新运行，并由独立架构解释器核对结果与退休数：

| 微基准 | 第一步周期 | 第二步周期 | IPC |
| --- | ---: | ---: | ---: |
{probe_rows}

热Load依赖链中，旧实现有12,798次请求间隔为六周期，新实现有12,780次为五周期。其IPC提升约19.84%，但全部六项程序的几何平均只提升0.69%；微基准收益不代表完整应用收益。

三个结构候选均跑过六项性能筛选。将“任何Store存在”作为阻断条件的版本较保守，IPC为{screens['any']['ipc_geomean']:.6f}，未追加PPA；收到地址后直接比较较老Store的版本与选定版本周期完全相同，面积{screens['older']['area_um2']:,.2f} µm²、频率{screens['older']['fmax_mhz']:.2f} MHz。选定的预计算版本多约168 µm²，频率达到{after['fmax_mhz']:.2f} MHz，提供更大余量。

## 每步完整验收

两步分别完成：25个官方程序、81组参数的324项静态检查、九组配置的27条随机退休差分、243次矩阵程序运行（225官方、18本地smoke），以及`make unit`、`make lint`、17组deep配置、28项HUM/标签回归和7,168项顶层所有权边界检查，全部通过。

Load新增定向测试覆盖省拍、反压稳定、较年轻Store不阻挡、ROB回绕中的较老Store阻挡/转发、恢复同拍取消、陈旧LSQ generation和错误ROB身份。旧路径在1/2/4宽度下均按预期不能通过省拍检查；新实现通过。这些预期失败与最初边界测试环境的失败均保留，未当作通过记录。

`qualify.py`在进入下一步前封存RTL、测试与工具输入，`compare.py`重新核对历史快照和日志哈希、选定RTL与测量副本一致性，以及官方仿真与计数器仿真的六项周期一致性。固定目录的原始证据位于`build/load-path-20261014/`；复现方法见[实验README](../experiments/load_path_20261014/README.md)，摘要见[results-summary.json](../experiments/load_path_20261014/results-summary.json)。

## 结论边界

最终最小周期为{after['minimum_period_ns']:.9f} ns，在300 MHz门槛上有约4.32%频率余量；2.0 ns目标下setup slack为−1.194786 ns，尚未达到500 MHz加分目标。频率来自官方理想时钟、无寄生参数和FakeRAM模型，不是布局布线或hold签核。

本轮完成了报告要求的第一步省拍目标。较老Store存在时仍保守回退，分支错误、Store退休和流式缺失仍限制整体IPC，不能据此宣称达到最高档。
'''
    (ROOT/'docs/load-path-optimization-20261014.md').write_text(text)
    print('PASS final comparison', result['load_change_percent'], 'remaining IPC gain',
          result['ipc_gain_remaining_percent'])


if __name__ == '__main__':
    main()
