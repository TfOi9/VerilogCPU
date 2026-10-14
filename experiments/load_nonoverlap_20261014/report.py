#!/usr/bin/env python3
"""Render the qualified fresh official comparison as a Chinese design report."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main():
    result = json.loads((HERE/'results-summary.json').read_text())
    assert result['completed'] and result['passed']
    before, after = (result['stages'][n] for n in ('baseline', 'candidate'))
    change = result['change_percent']
    rows = []
    for a, b in zip(before['cases'], after['cases']):
        if 'ipc' in a:
            rows.append('| {} | {:,} | {:,} | {:+.2f}% |'.format(
                a['name'].removeprefix('perf_'), a['cycles'], b['cycles'],
                (b['cycles']/a['cycles']-1)*100))
    probes = []
    for name in dict.fromkeys(r['probe'] for r in result['probes']):
        a, b = [r for r in result['probes'] if r['probe'] == name]
        assert a['stage'] == 'baseline' and b['stage'] == 'candidate'
        probes.append('| {} | {:,} | {:,} | {:+.2f}% |'.format(name, a['cycles'], b['cycles'],
            (b['ipc']/a['ipc']-1)*100))
    validation = result['validation']
    text = f'''# 较老Store不重叠时的Load路径优化验收

本轮已通过完整资格回归。Load收到地址时，所有较老Store地址已知、合法且字节不重叠，即可直接保存请求，省去一拍地址数组扫描。Store数据尚未就绪也可以使用该路径。六程序IPC由**{before['ipc_geomean']:.6f}**提高到**{after['ipc_geomean']:.6f}（{change['ipc_geomean']:+.2f}%）**。

## 最新官方同配置比较

官方仓库重新fetch后仍为`{result['framework_revision']}`。基线为`f50d34e`，优化前后均在本轮重新运行25个官方程序及原始官方综合脚本。FE2/BE2、PRF64、ROB32、恢复4、LSQ8、Store提示16、I1 KiB单路、D16 KiB两路、外存10周期保持一致。

使用Yosys0.63、OpenSTA3.1.0和固定ASAP7库；官方2.0 ns目标、ABC驱动`INVx1_ASAP7_75t_R`、负载5.0 fF。没有使用FAST_SYNTH或定制网表修复。新测基线逐值复现上一轮最终结果，资格脚本核对了源码、脚本、库、输入和产物哈希。

| 版本 | 六程序IPC几何平均 | 总面积 µm² | 官方估计频率 MHz | 最小周期 ns |
| --- | ---: | ---: | ---: | ---: |
| 优化前 | {before['ipc_geomean']:.6f} | {before['area_um2']:,.2f} | {before['fmax_mhz']:.2f} | {before['minimum_period_ns']:.9f} |
| 不重叠省拍 | {after['ipc_geomean']:.6f} | {after['area_um2']:,.2f} | {after['fmax_mhz']:.2f} | {after['minimum_period_ns']:.9f} |
| 变化 | {change['ipc_geomean']:+.2f}% | {change['area_um2']:+.2f}% | {change['fmax_mhz']:+.2f}% | |
| 最高基础档要求 | ≥1.098500 | ≤36,000 | ≥300 | |

IPC乘估计频率得到的吞吐量指标变化为{result['estimated_throughput_change_percent']:+.2f}%，仅用于同一官方模型下的比较。仍未达到最高基础档，IPC还需提高{result['ipc_gain_remaining_percent']:.2f}%；500 MHz加分目标也未达到。频率采用官方理想时钟、无寄生参数、FakeRAM模型，不能代替布局布线或hold签核。

新版本最差路径起于总线桥接器寄存器，止于整数保留站寄存器，包含{result['critical_paths']['candidate']['combinational_stages']}级组合逻辑和{result['critical_paths']['candidate']['buffers_inverters']}级buffer/inverter；到达时间由{result['critical_paths']['baseline']['arrival_ns']:.3f} ns变为{result['critical_paths']['candidate']['arrival_ns']:.3f} ns。源定位来自官方映射网表的保留属性，仅定位到时序块，未确定具体状态位。频率余量约{(after['fmax_mhz']/300-1)*100:.2f}%，低于优化前，因此本步取舍是提高IPC、减少面积并维持300 MHz门槛，最大估计频率下的吞吐量没有提高。

## 结构和正确性边界

正式RTL仅修改`rv32_load_store_queue.v`的捷径冲突选择。`older_store_mask`由已注册的busy、Store类型与ROB年龄产生；`incoming_store_conflict`并行比较输入Load与每项Store的地址及四位字节掩码。两向量相与后归约OR，判断是否可直接装入已有请求寄存器。

地址检查保证访问自然对齐且不跨32位字；字地址不同，或同字内字节掩码不相交，均不重叠。任何未知较老地址或字节重叠都回退到原有等待/逐字节转发路径。MMIO和异常Store在捷径中保守回退；完整ROB/LSQ标签核对、单AGU仲裁、恢复/flush取消和请求反压保持原有规则。已有待发Store和Load仍优先，Cache三周期命中契约保持。接线细节见[LSQ设计](lsq.md)。

| 官方性能程序 | 优化前周期 | 优化后周期 | 周期变化 |
| --- | ---: | ---: | ---: |
{chr(10).join(rows)}

`vvadd`增加75周期，其他五项改善。本轮确认了这项回退，尚未进一步隔离其调度原因；几何平均采用全部六项，未排除回退程序。

## 独立区间模型和完整回归

每个定向配置覆盖784组合法访问组合：Store/Load的BYTE/HALF/WORD、自然对齐偏移、同字/相邻字/远地址、Store数据就绪/未就绪、ROB回绕/不回绕。独立模型用字节地址区间判定重叠，通过真实分配、地址、请求、响应及完成握手检查省拍、反压、符号扩展、完整转发与部分覆盖等待；不读取DUT内部冲突判定。

定向测试在18种BE1/2/4、ROB16/32/64、posted/result-bypass关/开组合上通过，共{validation['targeted_checks']:,}项检查；优化前RTL在三个宽度下均按预期拒绝省拍断言。另覆盖多个较老Store、任一未知或重叠Store、同拍AGU仲裁、地址异常和MMIO。旧测试继续覆盖恢复、槽位复用、错误响应和在途容量。

完整回归全部通过：25官方程序；81组参数的324项静态检查；九组代表配置的27条随机退休差分及243次程序运行（225官方、18本地smoke）；`make unit`、`make lint`、17组deep配置、28项HUM/标签回归和7,168项返回所有权边界检查。以上属于完整项目回归，并非形式化穷尽证明。

| 通用混合访存微基准 | 优化前周期 | 优化后周期 | IPC变化 |
| --- | ---: | ---: | ---: |
{chr(10).join(probes)}

三个微基准由独立架构解释器计算结果和动态指令数，在优化前后官方模拟器上重新运行。它们证明不重叠路径有收益、完全重叠转发路径保持周期；微基准收益不能代替六程序官方IPC。

## 证据与复现

原始证据位于`build/load-nonoverlap-20261014/`：两份冻结RTL和官方PPA、矩阵、单元/HUM日志、定向正/负测试、微基准，以及资格源文件和固定目录单元测试归档。最初审核器因Verilog消息首字符被截断而未匹配预期拒绝，其失败保留；修正审核器后在独立目录重新验证，没有修改RTL或覆盖失败记录。

[实验README](../experiments/load_nonoverlap_20261014/README.md)列出命令与timeout；[资格摘要](../experiments/load_nonoverlap_20261014/candidate-results.json)记录完整门槛，[比较摘要](../experiments/load_nonoverlap_20261014/results-summary.json)保存前后结果及日志哈希。`qualify.py`核对测量副本与正式RTL逐字节一致，冻结资格输入，并审核全部历史证据。原有未提交文件保持原状，本轮只做本地提交。
'''
    path = ROOT/'docs/load-nonoverlap-optimization-20261014.md'
    path.write_text(text)
    print('PASS report', path)


if __name__ == '__main__':
    main()
