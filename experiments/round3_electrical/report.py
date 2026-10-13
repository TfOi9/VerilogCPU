#!/usr/bin/env python3
"""Validate evidence freshness and join IPC with electrically closed PPA."""
import json
import math
from pathlib import Path
import re
from repair import ROOT, EXP, OUT, digest, verify
from combined import CONFIGS, stage

VARIANTS = ('baseline', 'lsq-turnover', 'rs-ready-cut', 'combined')
PERF = ('median', 'multiply', 'qsort', 'rsort', 'towers', 'vvadd')
MICRO = ('dependent-add', 'independent-add', 'hot-load', 'hot-store', 'rs-pressure', 'mdu-pressure')


def read(path):
    return json.loads(path.read_text())


def require(condition, message):
    if not condition:
        raise ValueError(message)


def geometric(values):
    return math.exp(sum(math.log(x) for x in values)/len(values))


def main():
    verify()
    combined = stage()
    previous_path = ROOT/'experiments/round2_20261013/results-summary.json'
    previous = read(previous_path)
    checked, artifacts = {}, {}

    def hashes(expected):
        for filename, sha in expected.items():
            if filename not in checked:
                checked[filename] = digest(Path(filename))
            require(checked[filename] == sha, 'stale input: '+filename)

    def retain(path):
        artifacts[str(path)] = digest(path)

    require(previous['completed'] and previous['regression_passed'], 'previous regression incomplete')
    hashes(previous['artifact_sha256'])
    hashes(previous['experiment_tool_sha256'])
    retain(previous_path)
    unit, matrix = read(combined/'unit.json'), read(combined/'matrix.json')
    require(unit['passed'] and matrix['completed'] and matrix['passed'] and matrix['sources_unchanged'],
            'combined regression failed')
    hashes(matrix['source_sha256'])
    require(len(matrix['matrix']) == 81 and len(matrix['checks']) == 381, 'matrix coverage changed')
    require(all(r['completed'] and r['passed'] and all(x['passed'] for x in r['results'])
                for r in matrix['functional']), 'functional matrix failed')
    for width in (1, 2, 4):
        p = combined/f'directed/run-{width}.log'
        text = p.read_text()
        require(bool(re.search(r'(?m)^PASS', text)) and not re.search(r'(?m)^(FAIL|ERROR)\b', text),
                'LSQ response boundary failed')
        retain(p)
    for p in (combined/'unit.json', combined/'matrix.json', combined/'manifest.json'):
        retain(p)
    test_log = OUT/'checks-unit.log'
    text = test_log.read_text()
    require('Ran 3 tests' in text and text.rstrip().endswith('OK'), 'negative controls failed')
    retain(test_log)
    closed_path = OUT/'closed-summary.json'
    closed = read(closed_path)
    expected = {(v, '{}x{}-p{}-r{}'.format(*c)) for c in CONFIGS for v in VARIANTS}
    require(len(closed) == 16 and {(r['variant'], r['config']) for r in closed} == expected,
            'closure coverage incomplete')
    rows = []
    official_names = sorted(p.name for p in (ROOT.parent/'RISC-V-CPU-2026-Testcases').glob('correctness_*'))
    official_names += ['perf_'+p for p in PERF]
    for c in CONFIGS:
        name = '{}x{}-p{}-r{}'.format(*c)
        sim = combined/'sim'/name
        hashes(read(sim/'sources.json'))
        sim_sha = digest(sim/'sim')
        cases = {}
        for case in official_names+list(MICRO):
            p = sim/(case+'.json')
            r = read(p)
            require(r['passed'] and all(r['checks'].values()) and r['sim_sha256'] == sim_sha,
                    'combined simulation failed or stale')
            require(r['profile']['counts']['counter_schema_version'] == 2, 'counter schema differs')
            hashes({r['command'][1]: r['image_sha256']})
            cases[case] = r
            retain(p)
        ipc = geometric([cases['perf_'+p]['ipc'] for p in PERF])
        synth_driver = read(combined/'synth'/(name+'.json'))
        require(synth_driver['completed'] and synth_driver['passed'] and synth_driver['sources_unchanged'],
                'combined native synthesis incomplete')
        hashes(synth_driver['source_sha256'])
        retain(combined/'synth'/(name+'.json'))
        config_rows = []
        for variant in VARIANTS:
            run = next(r for r in closed if r['variant'] == variant and r['config'] == name)
            require(run['completed'] and run['passed'], 'candidate closure failed')
            hashes({str(EXP/'hold.py'): run['identity']['hold_code_sha256'],
                    str(EXP/'repair.py'): run['identity']['repair_code_sha256'],
                    str(Path(run['history'][0]['directory'])/'design.json'): run['identity']['source_design_sha256']})
            directory = Path(run['final_directory'])
            repair_root = OUT/'optimized'/variant/name
            repair_run = read(repair_root/'run.json')
            raw = combined/'synth'/name/'opt' if variant == 'combined' else ROOT/'build/round2-20261013'/variant/'synth'/name/'opt'
            hashes({str(raw/'design.json'): repair_run['identity']['design_sha256'],
                    str(EXP/'repair.py'): repair_run['identity']['repair_code_sha256']})
            raw_report = read(raw/'report.json')
            hashes({x['path']: x['sha256'] for x in raw_report['libraries']})
            hashes(read(repair_root/'boundary.json')['inputs_sha256'])
            require('Networks are equivalent' in (repair_root/'abc.log').read_text(), 'initial CEC failed')
            retain(repair_root/'abc.log')
            for p in [repair_root, *[Path(h['directory']) for h in repair_run['history'][1:]],
                      *[Path(h['directory']) for h in run['history'][1:]]]:
                require('Networks are equivalent' in (p/'reconstruction-cec.log').read_text(),
                        'reconstruction CEC failed')
                retain(p/'reconstruction-cec.log')
                for f in ('original.blif', 'reconstructed.blif', 'design.json'):
                    retain(p/f)
            result, hold = read(directory/'report.json'), read(directory/'hold.json')
            electrical = result['electrical']
            require(result['equivalence_passed'] and electrical['electrical_pass'] and hold['passed'],
                    'equivalence or electrical checks failed')
            hashes(electrical['input_sha256'])
            path_audit = read(directory/'path-audit.json')
            hashes(path_audit['artifact_sha256'])
            def sdc_commands(path):
                return sorted(s.strip() for s in path.read_text().splitlines() if s.strip() and not s.startswith('#'))
            require(sdc_commands(directory/'constraints.sdc') == sdc_commands(raw/'constraints.sdc'),
                    'actual SDC commands changed')
            require(result['area']['sram_instances'] == raw_report['area']['sram_instances'], 'SRAM changed')
            if variant == 'combined':
                v_ipc = ipc
                cycles = {k: v['cycles'] for k, v in cases.items()}
            else:
                old = next(r for r in previous['rows'] if r['variant'] == variant and r['config'] == name)
                v_ipc = old['ipc_geomean']
                cycles = {**old['official_cycles'], **old['micro_cycles']}
            raw_electrical = read(raw.parent/'electrical/report.json')
            hashes(raw_electrical['input_sha256'])
            area, frequency = result['area']['area_um2'], result['timing']['estimated_fmax_mhz']
            row = {'variant': variant, 'config': name, 'ipc_geomean': v_ipc,
                   'ipc_evidence': 'fresh combined simulation' if variant == 'combined' else 'validated round2 reuse; mapped CEC preserves cycles',
                   'fmax_mhz': frequency, 'area_um2': area, 'estimated_mips': v_ipc*frequency,
                   'estimated_mips_per_1000um2': v_ipc*frequency/area*1000,
                   'minimum_period_ns': result['timing']['minimum_period_ns'],
                   'setup_slack_at_2ns': result['timing']['worst_setup_slack_ns'],
                   'raw_fmax_mhz': raw_report['timing']['estimated_fmax_mhz'],
                   'raw_area_um2': raw_report['area']['area_um2'],
                   'raw_cap_violating_pins': raw_electrical['max_capacitance']['violating_pins'],
                   'raw_slew_violating_pins': raw_electrical['max_slew']['violating_pins'],
                   'cap_violating_pins': electrical['max_capacitance']['violating_pins'],
                   'slew_violating_pins': electrical['max_slew']['violating_pins'],
                   'hold_violating_endpoints': hold['violating_endpoints'],
                   'hold_before_padding': run['history'][0]['violating_endpoints'],
                   'worst_hold_slack_ns': hold['worst_slack_ns'],
                   'electrical_pass': True, 'equivalence_passed': True,
                   'fixed_cells': result['fixed_cells'], 'sram_area_um2': result['area']['sram_area_um2'],
                   'cycles': cycles, 'critical_path': path_audit['checks'][0],
                   'final_directory': str(directory)}
            for p in (directory/'report.json', directory/'hold.json', directory/'hold.rpt',
                      directory/'hold_paths.json', directory/'path-audit.json', directory/'constraints.sdc',
                      repair_root/'run.json', OUT/'closed'/variant/name/'run.json', raw/'report.json', raw.parent/'electrical/report.json'):
                retain(p)
            config_rows.append(row)
        baseline, lsq, rs, combo = config_rows
        require(rs['cycles'] == baseline['cycles'], 'RS cycles differ from baseline')
        require(combo['cycles'] == lsq['cycles'], 'combined cycles differ from LSQ')
        for row in config_rows:
            row['delta_percent_vs_closed_baseline'] = {k: (row[k]/baseline[k]-1)*100
                for k in ('ipc_geomean', 'fmax_mhz', 'area_um2', 'estimated_mips', 'estimated_mips_per_1000um2')}
        rows.extend(config_rows)
    retain(closed_path)
    result = {'completed': True, 'baseline_rtl': previous['baseline_head'], 'electrical_pass': True,
              'production_and_sora_unchanged': True, 'rows': rows, 'configs': len(CONFIGS), 'variants': list(VARIANTS),
              'new_combined_validation': {'unit_pass_lines': unit['pass_lines'], 'matrix_configs': len(matrix['matrix']),
                  'matrix_checks': len(matrix['checks']), 'functional_runs': sum(len(r['results']) for r in matrix['functional']),
                  'lsq_boundary_widths': [1, 2, 4], 'official_runs': len(CONFIGS)*len(official_names),
                  'micro_runs': len(CONFIGS)*len(MICRO), 'negative_controls': 3},
              'previous_regression_reused': previous['regressions'], 'artifact_sha256': artifacts,
              'tool_sha256': {str(ROOT/'.deps/yosys/bin'/n): digest(ROOT/'.deps/yosys/bin'/n) for n in ('yosys', 'yosys-abc')},
              'experiment_tool_sha256': {str(p): digest(p) for p in sorted(EXP.glob('*.py'))}}
    result['tool_sha256'][str(ROOT/'.deps/opensta/bin/sta')] = digest(ROOT/'.deps/opensta/bin/sta')
    (EXP/'results-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    write_report(result)
    verify()
    stage()
    print('Validated 16 electrically closed candidates; combined cycles match LSQ in all 124 runs.')
    for row in rows:
        d = row['delta_percent_vs_closed_baseline']
        print(row['config'], row['variant'], f"IPC {row['ipc_geomean']:.6f}",
              f"MHz {row['fmax_mhz']:.3f}", f"area {row['area_um2']:.2f}",
              f"delta frequency {d['fmax_mhz']:.2f}% MIPS {d['estimated_mips']:.2f}%")


def write_report(result):
    rows = result['rows']
    label = {'baseline': '基线', 'lsq-turnover': 'LSQ', 'rs-ready-cut': 'RS', 'combined': 'LSQ+RS'}
    lines = ['# 第三轮优化：映射电气修复与 LSQ+RS 组合实验', '',
        '日期：2026-10-14。本轮沿用隔离实验边界，正式 RTL 基线为 `'+result['baseline_rtl']+'`。', '',
        '## 结论', '',
        '已实现组合网表的高扇出缓冲、驱动尺寸调整、输出负载修复与短路径 hold 修复，并完成 LSQ 消泡和 RS 切断的组合实验。四个版本、四种配置共 16 个候选，在原 Liberty 与相同实际 SDC 下，最大电容、最大转换时间和 hold 违例均为 0。原始 FF、SRAM 和 tie 单元保持原类型、连接和属性；所有组合边界等价检查通过。', '',
        '统一修复流程后，RS 单独方案在四配置的频率收益均为正：2×2 为 6.89%，1×1 为 21.51%，4×1 为 18.47%，4×4 为 7.60%。上一轮未缓冲映射的 1×1 结果不能用于否定这一结构优化；此前的负收益受到映射驱动不足影响。只有四个已测配置、此套库和此优化流程支持本结论，不能外推到所有参数或布局后频率。', '',
        '组合方案在 124 次程序运行中与 LSQ 单独方案逐项周期完全一致；RS 单独方案沿用上一轮已验证的周期，与基线逐项一致。主配置组合方案 IPC 0.295537、频率估计 206.04 MHz、总面积 20741.86 µm²；相对同样完成电气和 hold 修复的基线，IPC×频率提高 15.15%，面积增加 1.00%。', '',
        '正式 `rtl/`、测试工具及 SORA 均未改动。新实验、报告和等价检查工具独立保存，尚未合入正式实现。', '',
        '## 完整 IPC、频率与面积对比', '',
        '配置写作 FE×BE/P物理寄存器数/R ROB项数。IPC 为内存延迟 10 周期时六项官方性能程序的等权几何平均。面积为逻辑加 SRAM 的官方 FakeRAM 估计；MIPS 是 IPC×频率的模型估计。各版本均使用相同 cache 和总线参数。', '',
        '| 配置 | 版本 | IPC | 原映射 MHz | 修复后 MHz | 原面积 µm² | 修复后面积 µm² | 估计 MIPS |',
        '|---|---|---:|---:|---:|---:|---:|---:|']
    for r in rows:
        lines.append(f"| {r['config']} | {label[r['variant']]} | {r['ipc_geomean']:.6f} | {r['raw_fmax_mhz']:.2f} | {r['fmax_mhz']:.2f} | {r['raw_area_um2']:.2f} | {r['area_um2']:.2f} | {r['estimated_mips']:.2f} |")
    lines += ['', '原映射均有严重电气违例，原始频率只是该映射模型中的推算值。修复前后频率的大幅变化主要体现物理映射流程的改善，不能归因于 RTL IPC 优化；结构方案应按下面同流程基线比较。', '',
        '| 配置 | 组合 IPC增益 | 组合频率增益 | 组合面积变化 | 组合 MIPS增益 | 组合 MIPS/面积增益 |',
        '|---|---:|---:|---:|---:|---:|']
    for r in rows:
        if r['variant'] == 'combined':
            d = r['delta_percent_vs_closed_baseline']
            lines.append('| '+r['config']+' | '+' | '.join(f'{d[k]:+.2f}%' for k in
                ('ipc_geomean', 'fmax_mhz', 'area_um2', 'estimated_mips', 'estimated_mips_per_1000um2'))+' |')
    lines += ['', 'LSQ 单独消泡在 2×2 仍有约 1.97% 频率损失，但 IPC 提升使估计 MIPS 增加 5.13%。组合方案四配置均提高估计 MIPS 与面积效率。当前负载下扩大发射宽度并未提高绝对吞吐，不能按 BE_WIDTH 单项选择配置。', '',
        '## 电气与时序检查', '',
        '| 配置 | 版本 | 原 cap引脚 | 原 slew引脚 | 修复后 cap/slew | 补短路径前 hold端点 | 最终 hold端点 | 最坏 hold裕量 ps |',
        '|---|---|---:|---:|---|---:|---:|---:|']
    for r in rows:
        lines.append(f"| {r['config']} | {label[r['variant']]} | {r['raw_cap_violating_pins']} | {r['raw_slew_violating_pins']} | 0 / 0 | {r['hold_before_padding']} | 0 | {r['worst_hold_slack_ns']*1000:.5f} |")
    lines += ['',
        'cap/slew 根据每个库和引脚的原始限制判断。ASAP7 不存在本实验可统一套用的“4 ns 最大转换时间”：INVBUF 等库的默认值为 320 ps，其他库部分默认值为 4000 ps，许多引脚还有显式 320 ps 限制。审计使用 OpenSTA 实际约束，不修改 Liberty。未定义最大 fanout 约束时记录 `not_constrained`，不把缺失约束计为签核通过。', '',
        '全部实际 SDC 命令经规范化逐项比较，与各原映射一致：2 ns 目标周期、0.05 ns 时钟不确定度和输入转换时间、0.2 ns 最大接口延迟、0 ns 最小接口延迟、5 fF 每个输出引脚负载、reset=0、理想时钟。没有用放宽约束获得 PASS。ABC 的 INVx1 输入驱动和 5 fF 输出负载仅用于修复启发式，不替换 STA 环境。', '',
        '16 个候选都未满足原始 2 ns/500 MHz 的 setup 目标。表中的频率采用原官方分析器搜索得到的最小周期估计，原 2 ns 下的负 setup slack 保存在结构化结果中。hold 是对原 SDC 的独立最短路径检查；先前只搜索 setup/min-period/min-pulse 并不能证明 hold 通过。', '',
        '最终最小 hold 裕量约 0.00754 ps，仅表示 TT、理想时钟、无互连寄生模型中非负；没有可宣称的物理裕量。尚无布局、CTS、RC 提取、多 PVT/OCV 或时钟偏斜检查，因此这些频率、面积和零违例结果不是芯片签核。短路径填充以真实违例为输入，本轮各候选一次填充收敛，后续需加入正裕量目标并重新测面积/频率。', '',
        '## 实现结构与接线', '',
        '1. 从官方映射 JSON 切出纯组合网络，以顶层输入和所有原 FF/SRAM/tie 输出作为输入边界，以顶层输出和所有原状态单元输入作为输出边界。常量按独立符号输入证明后恢复为原常量，不假设只出现合法 CPU 状态；边界别名重建后再次证明。', '',
        '2. ABC 执行 `buffer -p -N 8 -S 100` 与 `upsize -D 2000 -T 30`，保留原状态单元，不移动寄存器。重建全网表时以锚点恢复原连接，检查顶层端口以及每个原固定单元完整字典一致，再对重建后的全组合边界执行 CEC。', '',
        '3. 对剩余 cap/slew 违例，原组合驱动输出改接新内部节点，经过 BUFx2→BUFx8 接回原网线；必要时增加末级驱动尺寸。实际顶层多个别名引脚的总负载由 OpenSTA 审计覆盖，避免 ABC 去重输出忽略负载。', '',
        '4. 对 hold 违例，由原组合输出经 BUFx2×3→BUFx8 接回原网线，所有原 FF/SRAM 输入连接保持不变。填充后重新检查等价、cap/slew 和 hold。若违例直接来自顶层输入或固定状态单元，工具会失败，要求专门的逐引脚边界处理；本轮未遇到这类未完成修复。', '',
        '5. LSQ+RS 的 RTL 副本只叠加上一轮的 LSQ 响应交接准备下一请求，以及 INT/MDU RS 不使用当拍腾槽。仍是单笔 cache 请求在途，不增加 MSHR，不改变 Store/MMIO 的提交与错误收尾协议。', '',
        '## 验证范围与证据', '',
        '本轮新组合 RTL 完整单元套件：186 条 PASS；LSQ 响应边界定向测试：BE=1/2/4，包含请求/完成背压、错误、恢复和过期响应；完整 81 参数矩阵：381 项检查、207 次功能运行；四配置各 19 个正确性、6 个官方性能和6个通用微基准，共100次官方运行、24次微基准，全部通过性能计数守恒。Verilog 编译继续使用 2005 标准。', '',
        'baseline/LSQ/RS 的 RTL 回归和 IPC 复用上一轮已完成证据，重新校验其源文件、工具和原始结果哈希；本轮没有重复宣称又跑了这三组的全部程序。原12份映射逐一进行了新电气修复，组合版本新增4份官方综合。16个候选各通过初始组合 CEC 及每次重建 CEC；完整固定单元/端口检查证明纯组合修复不改变周期功能。未执行标准单元门级 SDF 仿真。', '',
        '新增3项真实 CPU 网表负向控制：改坏 FF 的 D 输入、改名顶层 reset 接口、将可观察的 hold 缓冲改为反相器；分别被固定单元检查、接口检查、重建 CEC 拦截。修复流程不能仅依赖子进程返回0来宣称成功。', '',
        '性能计数保持上一轮口径：动态指令数包含结束 MMIO Store，而 harness 在其 B 响应时结束，退休数应为动态指令数减1。Store 的 RUN/非RUN阶段是 D-cache 状态代理，不能分解为精确的 MMIO或命中耗时；array_commit 只观测命中 Store。', '',
        '## 剩余瓶颈与下一步', '',
        '| 组合配置 | 最长路径组合单元级数 | 其中 BUF/INV级数 | 到达时间 ns |',
        '|---|---:|---:|---:|']
    for r in rows:
        if r['variant'] == 'combined':
            p = r['critical_path']
            lines.append(f"| {r['config']} | {p['combinational_stages']} | {p['buffer_inverter_stages']} | {p['arrival_ns']:.3f} |")
    lines += ['',
        '路径计数来自 OpenSTA source_path 同一单元输入→输出弧，含缓冲/反相级，不是 RTL 流水级。四组组合最长路径起点均保留 `rv32_completion_writeback_network.v:315-375` 的来源；4×1 终点保留 MDU RS 状态来源。其余终点的原综合流程已清除 RTL 网络名和部分 src 属性，无法仅凭本报告精确命名完整逻辑链，不能把深度全部归因于某个模块。重映射组合单元也不保留原RTL归属。', '',
        '1. **优先缩短写回广播至 rename/派发/RS 的组合链。** 下一隔离实验保存映射前信号对应关系，分开测容量前缀筛选、局部 ready 归并、唤醒/选择和多槽分配。代码中逐 lane 更新前缀计数、逐槽优先选择是候选；尝试平衡树的前缀和/多槽选择，以及证明容量筛选已蕴含局部 ready 后消除冗余依赖。分别等价/回归后比较关键路径，不能直接删除握手保护。本轮4×4在电气合格后仍有275级路径，扩宽问题已不只是扇出。', '',
        '2. **IPC优先处理 Store 队头等待。** 主配置组合实验 rsort 的 Store响应等待占64.03%周期，towers占70.29%。做提交 Store buffer 的独立实验，明确普通RAM store、MMIO、错误响应、转发及恢复的边界；保持MMIO严格等待，不能通过提前吞掉store fault获得IPC。所有等待占比来自互斥退休分区。', '',
        '3. **补取指供给与 Load 并行度实验。** multiply 中非恢复 Fetch空队列占66.67%周期，与退休分区不互斥，不能与其求和。先分解预测目标到首条有效取指、redirect丢弃和供给空拍。median队头Load未完成占45.47%，vvadd占42.86%；request queue/多笔在途与非阻塞cache应分别实验，LSQ消泡仍不提供miss并行度。', '',
        '4. **集成顺序。** 将同约束电气修复及更大的hold裕量验证纳入候选构建流程，再考虑正式集成LSQ+RS。四配置的组合结果均支持候选价值；沿用此前实验不合入正式RTL的约束，继续留在隔离目录。之后需多角、布局/CTS/RC复测，判断树化、流水化与增加缓冲的实际取舍。', '',
        f"复现脚本：[README]({EXP/'README.md'})；结构化证据：[results-summary.json]({EXP/'results-summary.json'})。", '',
        f'原始完整输出位于 `{OUT}`：官方综合、逐程序计数、矩阵、映射JSON/Verilog、BLIF和CEC日志、电气/hold报告、约束及输入哈希。`build/`按现有规则忽略，不进入本地提交。', '']
    (ROOT/'docs/round3-electrical-optimization.md').write_text('\n'.join(lines))


if __name__ == '__main__':
    main()
