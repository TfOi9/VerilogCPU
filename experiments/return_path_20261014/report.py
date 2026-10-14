#!/usr/bin/env python3
"""Write the qualified critical-path and throughput comparison in Chinese."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main():
    result = json.loads((HERE/'results-summary.json').read_text())
    assert result['completed'] and result['passed']
    selected = result['selected']
    before, after = result['rows']['baseline'], result['rows'][selected]
    prior = result['prior_load_version']
    changes = result['change_percent']
    labels = {'baseline': '当前基线', 'metadata-v2': '仅提前LSQ payload',
        'metadata-wb-v2': 'LSQ payload与写回数据并行（采用）',
        'rs-retain-v2': '仅保留整数RS payload',
        'metadata-wb-rs-v2': 'LSQ、写回与RS三项组合'}
    rows = '\n'.join('| {} | {:.6f} | {:,.2f} | {:.2f} | {:+.2f}% |'.format(
        labels[name], r['ipc_geomean'], r['area_um2'], r['fmax_mhz'],
        (r['ipc_geomean']*r['fmax_mhz']/(before['ipc_geomean']*before['fmax_mhz'])-1)*100)
        for name, r in result['rows'].items())
    original_path, final_path = result['original_path_state'], result['final_path_state']
    original_start = ', '.join(original_path['start']['rtl_state'])
    original_end = ', '.join(original_path['end']['rtl_state'])
    final_start = ', '.join(final_path['start']['rtl_state'])
    final_end = ', '.join(final_path['end']['rtl_state'])
    cases = '\n'.join('| {} | {:,} | {:,} |'.format(a['name'].removeprefix('perf_'),
        a['cycles'], b['cycles']) for a, b in zip(before['cases'], after['cases']) if 'ipc' in a)
    probes = '\n'.join('| {} | {:,} | {:,} |'.format(a['probe'], a['cycles'], b['cycles'])
        for a, b in zip(result['probes'][::2], result['probes'][1::2]))
    text = f'''# 总线返回至整数保留站的时序优化验收

本轮已完成完整正确性回归。采用LSQ返回payload选择与资格分离、写回广播数据与有效位分离两项改动，没有增加流水级。IPC保持**{after['ipc_geomean']:.6f}**，全部25个官方程序周期逐项不变，面积**{after['area_um2']:,.2f} µm²**，官方估计频率**{after['fmax_mhz']:.2f} MHz**。相对`07e32b8`，IPC乘频率提升**{result['throughput_change_percent']:.2f}%**，并追回此前**{prior['fmax_mhz']:.2f} MHz**的频率水平。

## 最新官方同配置比较

官方仓库重新fetch后仍为`{result['framework_revision']}`。本轮重新测量基线和四种修正后的结构候选：25个官方程序与原始官方PPA流程均完整执行。FE2/BE2、PRF64、ROB32、恢复4、LSQ8、Store提示16、I1 KiB单路、D16 KiB两路、外存10周期保持一致。

采用Yosys0.63、OpenSTA3.1.0、固定ASAP7库、2.0 ns目标、ABC驱动`INVx1_ASAP7_75t_R`和负载5.0 fF。脚本、库、RTL、投影输入和原始产物均按哈希审核，没有用FAST_SYNTH或定制网表修复替换官方成绩。

| 候选 | 六程序IPC | 总面积 µm² | 估计频率 MHz | IPC乘频率变化 |
| --- | ---: | ---: | ---: | ---: |
{rows}

正式代码采用吞吐量最高的两项组合。相对当前基线，面积变化{changes['area_um2']:+.2f}%，频率变化{changes['fmax_mhz']:+.2f}%，IPC不变。相对不重叠Load优化之前的`f50d34e`，IPC乘频率也提升**{result['throughput_vs_pre_nonoverlap_percent']:.2f}%**；因此已超过该次优化前的水平。RS保留payload方案虽有独立收益，合并后频率低于选定方案，本轮没有修改整数RS RTL。

以上吞吐量指标来自同一官方模型的IPC与估计频率。仍未达到最高基础档的IPC1.0985，也未达到500 MHz加分目标；时序采用理想时钟、无寄生参数和FakeRAM，不能代替布局布线或hold签核。

## 从时序块定位到状态位

通过官方综合脚本的精确pre-ABC前缀重放，将保留的顺序单元名称、类型、属性和端口宽度与最终网表对应，找到原最差路径：

`{original_start}` → `{original_end}`，到达时间{original_path['arrival_ns']:.3f} ns。

整数RS在发射移除时清零操作数，使返回唤醒、排序、发射移除也进入操作数寄存器的控制通路。单独保留无效槽payload的候选确认可改变该路径，但官方总吞吐量不如所选组合，故保留该实验而未合入。

选定版本的新最差路径：

`{final_start}` → `{final_end}`，到达时间{final_path['arrival_ns']:.3f} ns，最小周期{after['minimum_period_ns']:.9f} ns。最差端点从整数RS操作数转到LSQ地址寄存器。状态位定位是只读诊断，官方PPA文件没有被修改。

## 实现与接线

LSQ以注册的`source_valid`选择返回payload：空完成缓冲提前呈现在途tag、扩展值和异常字段，有缓冲结果则选择注册结果。有效性仍由`response_bypass`的完整身份、读类型、discard、Cache valid及恢复条件决定；只有有效握手才捕获、发送或释放Load项。关闭旁路时仍走原有注册结果。

写回网络直接输出选定物理号和值，让消费者的物理号比较与写回资格并行。`writeback_valid`仍执行原有ROB授权、握手、重复tag、异常和p0过滤；PRF、rename、全部RS只在有效广播时写入或捕获。valid为零时payload可变化且不保证为零。有缓冲结果与反压锁定的有效payload仍保持。

完整ROB/LSQ tag、ID复用、回滚迟到响应、逐字节转发及较老Store不重叠省拍规则保持。Cache三周期命中契约和全部流水级数量保持。结构与接线见[LSQ](lsq.md)、[完成写回](writeback.md)与[结果旁路](posted-stores-and-result-bypass.md)。

| 官方性能程序 | 优化前周期 | 优化后周期 |
| --- | ---: | ---: |
{cases}

| 混合访存微基准 | 优化前周期 | 优化后周期 |
| --- | ---: | ---: |
{probes}

三项微基准由独立架构解释器计算结果和动态指令数，使用两份官方模拟器重新运行。不重叠Store/Load依赖链和同字不同字节的省拍收益全部保留，完全重叠转发路径保持周期。

## 完整资格回归与证据

全部通过：25项官方程序；81组参数的324项静态检查；九组代表配置的27条随机退休差分和243次程序运行（225官方、18本地smoke）；`make unit`、`make lint`、17组deep配置、28项HUM/标签回归和7,168项返回所有权边界检查。

新增九组RS复用测试共36,864项检查，覆盖BE1/2/4、ROB16/32/64、无效广播、同拍唤醒发射、槽位复用、不同物理号、反压锁定、恢复及flush，并已加入`make unit`。隔离筛选另有22项LSQ/写回/ROB协议测试，以及基线和两个RS候选共54组测试，包含各候选九组1500周期的独立Python模型检查。以上为完整项目回归，不是形式化穷尽证明。

原始证据位于`build/return-path-20261014/`，包括五份官方仿真/PPA、精确状态位诊断、候选源码、完整矩阵与unit/lint/HUM日志、微基准及资格源文件归档。声明顺序首稿的Icarus失败和主动中止的PPA保留，未算作合格结果。

[实验README](../experiments/return_path_20261014/README.md)给出命令与timeout；[完整资格摘要](../experiments/return_path_20261014/final-results.json)及[比较摘要](../experiments/return_path_20261014/results-summary.json)保存原始证据哈希。资格脚本要求正式RTL与测量快照逐字节一致、所有官方周期与微基准周期保持、频率追回此前水平、IPC乘频率超过当前及不重叠优化之前，并保存固定目录单元结果的独立归档。本轮仅本地提交，保留原有未提交文件。
'''
    path = ROOT/'docs/return-path-optimization-20261014.md'
    path.write_text(text)
    print('PASS report', path)


if __name__ == '__main__':
    main()
