#!/usr/bin/env python3
"""Join only completed, fresh regression and identically qualified mapping evidence."""
import json
import math
import re
from pathlib import Path
from stage import ROOT, EXP, OUT, CONFIGS, VARIANTS, stage, digest, verify

PERF = ('median', 'multiply', 'qsort', 'rsort', 'towers', 'vvadd')
MICRO = ('dependent-add', 'independent-add', 'hot-load', 'hot-store', 'rs-pressure', 'mdu-pressure')


def read(path):
    return json.loads(path.read_text())


def need(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    manifest = stage()
    artifacts, checked = {}, {}
    def retain(path):
        if str(path) not in artifacts:
            artifacts[str(path)] = digest(path)
    def hashes(values):
        for filename, sha in values.items():
            if filename not in checked:
                checked[filename] = digest(Path(filename))
            need(checked[filename] == sha, 'stale evidence input: '+filename)
    previous_path = ROOT/'experiments/round3_electrical/results-summary.json'
    previous = read(previous_path)
    need(previous['completed'] and previous['electrical_pass'], 'previous round incomplete')
    hashes(previous['artifact_sha256'])
    hashes(previous['experiment_tool_sha256'])
    retain(previous_path)
    retain(OUT/'manifest.json')
    guards = (OUT/'guards.log').read_text()
    need('Ran 5 tests' in guards and guards.rstrip().endswith('OK'), 'negative controls incomplete')
    retain(OUT/'guards.log')
    selector = read(OUT/'selector-tests/results.json')
    need(selector['passed'] and len(selector['results']) == 21 and all(r['passed'] for r in selector['results']),
         'selector coverage incomplete')
    hashes(selector['source_sha256'])
    retain(OUT/'selector-tests/results.json')
    proofs = read(OUT/'rtl-equivalence.json')
    need(len(proofs) == 16 and all(r['passed'] for r in proofs), 'RTL state-cut proofs incomplete')
    expected_proofs = {(m, '{}x{}-p{}-r{}'.format(*c), op) for c in CONFIGS for m, op in (
        ('rv32_completion_writeback_network', 0), ('rv32_integer_reservation_station', 0),
        ('rv32_mdu_reservation_station_core', 0), ('rv32_mdu_reservation_station_core', 1))}
    need({(r['module'], r['config'], r.get('op_class', 0)) for r in proofs} == expected_proofs,
         'RTL proof parameter coverage differs')
    for proof in proofs:
        hashes(proof['source_sha256'])
        log = Path(proof['log'])
        need('Networks are equivalent' in log.read_text(), 'RTL CEC not equivalent')
        for p in (log, log.parent/'gold.blif', log.parent/'gate.blif', log.parent/'state-correspondence.json'):
            retain(p)
    retain(OUT/'rtl-equivalence.json')
    regression = []
    for variant in VARIANTS:
        base = OUT/variant
        unit, matrix = read(base/'unit.json'), read(base/'matrix.json')
        need(unit['passed'] and matrix['passed'] and matrix['completed'] and matrix['sources_unchanged'],
             'regression incomplete: '+variant)
        hashes(matrix['source_sha256'])
        need(len(matrix['matrix']) == 81 and len(matrix['checks']) == 381 and all(r['passed'] for r in matrix['checks']),
             'parameter coverage incomplete')
        need(all(r['passed'] and r['completed'] and all(x['passed'] for x in r['results']) for r in matrix['functional']),
             'functional matrix incomplete')
        regression.append({'variant': variant, 'unit_pass_lines': unit['pass_lines'], 'matrix_configs': 81,
                           'matrix_checks': len(matrix['checks']),
                           'functional_runs': sum(len(r['results']) for r in matrix['functional'])})
        for p in (base/'unit.json', base/'unit.log', base/'matrix.json'):
            retain(p)
    qualification = read(OUT/'common-qualification.json')
    native = read(OUT/'common-synthesis.json')
    expected = {(v, '{}x{}-p{}-r{}'.format(*c)) for c in CONFIGS for v in ('baseline',)+VARIANTS}
    for group in (qualification, native):
        need(len(group) == 16 and {(r['variant'], r['config']) for r in group} == expected and all(r['passed'] for r in group),
             'four-configuration mapping coverage incomplete')
    rows, simulations = [], []
    official = sorted(p.name for p in (ROOT.parent/'RISC-V-CPU-2026-Testcases').glob('correctness_*'))+['perf_'+p for p in PERF]
    for config in CONFIGS:
        name = '{}x{}-p{}-r{}'.format(*config)
        prior = next(r for r in previous['rows'] if r['variant'] == 'combined' and r['config'] == name)
        current_rows = []
        for variant in ('baseline',)+VARIANTS:
            if variant == 'baseline':
                cycles, ipc = prior['cycles'], prior['ipc_geomean']
            else:
                simdir = OUT/variant/'sim'/name
                hashes(read(simdir/'sources.json'))
                simsha = digest(simdir/'sim')
                cases = {}
                for case in official+list(MICRO):
                    p = simdir/(case+'.json')
                    r = read(p)
                    need(r['passed'] and all(r['checks'].values()) and r['sim_sha256'] == simsha,
                         'simulation failed or stale')
                    need(r['profile']['counts']['counter_schema_version'] == 2, 'counter schema changed')
                    hashes({r['command'][1]: r['image_sha256']})
                    cases[case] = r
                    retain(p)
                cycles = {k: r['cycles'] for k, r in cases.items()}
                ipc = math.exp(sum(math.log(cases['perf_'+p]['ipc']) for p in PERF)/6)
                need(cycles == prior['cycles'], 'cycle behavior changed: '+variant+' '+name)
                simulations.append({'variant': variant, 'config': name, 'official': len(official), 'micro': len(MICRO),
                                    'cycles_equal_to_previous_combined': True})
            mapped = next(r for r in native if r['variant'] == variant and r['config'] == name)
            hashes(mapped['identity']['source_sha256'])
            hashes(mapped['native_tools'])
            hashes({str(EXP/'common_synth.py'): mapped['identity']['flow_sha256']})
            raw = Path(mapped['report']).parent
            rawreport = read(raw/'report.json')
            hashes({x['path']: x['sha256'] for x in rawreport['libraries']+rawreport['inputs']})
            run = next(r for r in qualification if r['variant'] == variant and r['config'] == name)
            identity = run['identity']
            hashes({str(raw/'design.json'): identity['source_design_sha256'],
                    str(EXP/'margin.py'): identity['margin_code_sha256'],
                    str(EXP/'qualify_common.py'): identity['code_sha256'],
                    str(ROOT/'experiments/round3_electrical/repair.py'): identity['repair_code_sha256']})
            directory = Path(run['final_directory'])
            report, margin, hold = read(directory/'report.json'), read(directory/'margin.json'), read(directory/'hold.json')
            need(report['equivalence_passed'] and report['electrical']['electrical_pass'] and margin['passed'] and hold['passed'],
                 'electrical or hold margin failure')
            need(margin['worst_slack_ns'] >= 0.020 and margin['below_target_paths'] == 0, 'hold target missed')
            hashes(report['electrical']['input_sha256'])
            paths = read(directory/'path-audit.json')
            hashes(paths['artifact_sha256'])
            def sdc(path):
                return sorted(s.strip() for s in path.read_text().splitlines() if s.strip() and not s.startswith('#'))
            need(sdc(raw/'constraints.sdc') == sdc(directory/'constraints.sdc'), 'actual SDC changed')
            need(report['area']['sram_instances'] == rawreport['area']['sram_instances'], 'SRAM changed during repair')
            base = OUT/'common-qualified'/variant/name
            boundary = read(base/'electrical/boundary.json')
            hashes(boundary['inputs_sha256'])
            need('Networks are equivalent' in (base/'electrical/abc.log').read_text(), 'ABC repair proof failed')
            retain(base/'electrical/abc.log')
            sizing_text = (base/'electrical/abc.log').read_text().replace('\r', '\n')
            sizing_times = [float(t) for t in re.findall(r'^\s*\d+ Win:.*?\s([0-9.]+) sec', sizing_text, re.M)]
            need(bool(sizing_times), 'sizing iteration log missing')
            cec_count = 1
            for log in sorted(base.rglob('reconstruction-cec.log')):
                need('Networks are equivalent' in log.read_text(), 'physical reconstruction proof failed')
                cec_count += 1
                for p in (log, log.parent/'original.blif', log.parent/'reconstructed.blif'):
                    retain(p)
            raw_electrical = read(base/'raw-electrical/report.json')
            hashes(raw_electrical['input_sha256'])
            frequency, area = report['timing']['estimated_fmax_mhz'], report['area']['area_um2']
            row = {'variant': variant, 'config': name, 'ipc_geomean': ipc, 'cycles': cycles,
                   'fmax_mhz': frequency, 'area_um2': area, 'estimated_mips': ipc*frequency,
                   'mips_per_1000um2': ipc*frequency/area*1000,
                   'minimum_period_ns': report['timing']['minimum_period_ns'],
                   'setup_slack_at_2ns': report['timing']['worst_setup_slack_ns'],
                   'raw_fmax_mhz': rawreport['timing']['estimated_fmax_mhz'], 'raw_area_um2': rawreport['area']['area_um2'],
                   'raw_cap_pins': raw_electrical['max_capacitance']['violating_pins'],
                   'raw_slew_pins': raw_electrical['max_slew']['violating_pins'],
                   'cap_pins': report['electrical']['max_capacitance']['violating_pins'],
                   'slew_pins': report['electrical']['max_slew']['violating_pins'],
                   'hold_endpoints': hold['violating_endpoints'], 'min_hold_ps': margin['worst_slack_ns']*1000,
                   'hold_below_target_before': run['history'][0]['below_target_paths'],
                   'critical_path': paths['checks'][0], 'physical_cec_count': cec_count,
                   'fixed_cells': report['fixed_cells'], 'final_directory': str(directory),
                   'sizing_max_logged_seconds': max(sizing_times),
                   'previous_round_fmax_mhz': prior['fmax_mhz'], 'previous_round_area_um2': prior['area_um2']}
            if variant == 'baseline':
                legacy_path = OUT/'qualified/baseline'/name/'run.json'
                legacy = read(legacy_path)
                need(legacy['passed'] and legacy['target_ns'] == 0.020, 'legacy 20 ps baseline incomplete')
                legacy_dir = Path(legacy['final_directory'])
                legacy_report = read(legacy_dir/'report.json')
                legacy_margin = read(legacy_dir/'margin.json')
                need(legacy_margin['passed'] and legacy_report['electrical']['electrical_pass'], 'legacy baseline not qualified')
                hashes(legacy_report['electrical']['input_sha256'])
                row['legacy_20ps_fmax_mhz'] = legacy_report['timing']['estimated_fmax_mhz']
                row['legacy_20ps_area_um2'] = legacy_report['area']['area_um2']
                for p in (legacy_path, legacy_dir/'report.json', legacy_dir/'margin.json'):
                    retain(p)
            for p in (raw/'report.json', raw/'design.json', raw.parent/'run.json', base/'run.json',
                      base/'raw-electrical/report.json', directory/'report.json', directory/'design.json',
                      directory/'mapped.v', directory/'constraints.sdc', directory/'hold.json', directory/'hold.rpt',
                      directory/'margin.json', directory/'margin_paths.json', directory/'path-audit.json'):
                retain(p)
            current_rows.append(row)
        baseline = current_rows[0]
        for r in current_rows:
            r['delta_percent'] = {k: (r[k]/baseline[k]-1)*100 for k in
                                  ('ipc_geomean', 'fmax_mhz', 'area_um2', 'estimated_mips', 'mips_per_1000um2')}
        rows.extend(current_rows)
    for f in ('common-synthesis.json', 'common-qualification.json', 'baseline-reference.json', 'official-aborted.json'):
        retain(OUT/f)
    provenance = []
    for variant in ('baseline',)+VARIANTS:
        p = OUT/'provenance'/variant/'4x4-p64-r16/result.json'
        info = read(p)
        hashes(info['artifact_sha256'])
        retain(p)
        provenance.append(info)
    result = {'completed': True, 'production_and_sora_unchanged': True, 'hold_target_ps': 20,
              'flow': 'common expanded synth with opt -fast; unchanged libraries, FakeRAM, ABC and SDC',
              'baseline': 'previous round combined LSQ+RS RTL, freshly remapped and qualified to 20 ps',
              'regressions': regression, 'simulations': simulations, 'rtl_proofs': proofs,
              'selector_transactions': 21000, 'negative_controls': 5, 'rows': rows, 'state_provenance_4x4': provenance,
              'artifact_sha256': artifacts, 'source_manifest_sha256': digest(OUT/'manifest.json'),
              'experiment_sha256': {str(p): digest(p) for p in sorted(EXP.iterdir()) if p.suffix in ('.py', '.v')},
              'framework_sha256': {str(p): digest(p) for p in (ROOT.parent/'RISC-V-CPU-2026/scripts').glob('*.py')}}
    (EXP/'results-summary.json').write_text(json.dumps(result, indent=2)+'\n')
    write_markdown(result)
    stage()
    print('Validated complete tree experiment:', len(rows), 'PPA candidates')


def write_markdown(result):
    rows = result['rows']
    labels = {'baseline': '前轮组合基线', 'tree-wb': '写回树', 'tree-rs': 'RS树', 'tree-all': '两者组合'}
    best = {name: max((r for r in rows if r['config'] == name), key=lambda r: r['estimated_mips'])
            for name in dict.fromkeys(r['config'] for r in rows)}
    main4 = best['4x4-p64-r16']
    wide = {r['variant']: r for r in rows if r['config'] == '4x4-p64-r16'}
    lines = ['# 写回到派发/RS树化与正hold裕量实验', '', '日期：2026-10-14。', '',
        '## 结论与比较口径', '',
        f"4×4配置中，估计吞吐最高的是{labels[main4['variant']]}：IPC {main4['ipc_geomean']:.6f}、频率{main4['fmax_mhz']:.2f} MHz、面积{main4['area_um2']:.2f} µm²。相对同流程、同20 ps hold目标的基线，频率{main4['delta_percent']['fmax_mhz']:+.2f}%，面积{main4['delta_percent']['area_um2']:+.2f}%。", '',
        f"4×4单独写回树化的频率增益为{wide['tree-wb']['delta_percent']['fmax_mhz']:.2f}%，单独RS树化为{wide['tree-rs']['delta_percent']['fmax_mhz']:.2f}%，主要收益来自RS选择链。组合最长路径由{wide['baseline']['critical_path']['combinational_stages']}级降至{wide['tree-all']['critical_path']['combinational_stages']}级；独立版本的关键路径会移动，频率增益不能简单相加。", '',
        '本轮基线是上一轮LSQ消泡+RS当拍腾槽切断组合。三个树化候选都重新完成完整回归；372次官方/微基准逐项周期与该基线相同。没有增加流水拍，IPC收益为0，目标是用结构变换提高频率。', '',
        '原官方合成在4×4树化候选上长时间进入Yosys opt_muxtree递归搜索；进程采样定位后停止，原日志及中止状态保留，未把未完成综合算为成功。另立统一流程，将Yosys synth展开并把opt调用替换为opt -fast，其他层次展开、FSM、算术、存储、dfflibmap、ABC、FakeRAM与STA步骤保留。基线和全部候选均按该流程完成四配置重新综合，不能把本表增益归因于只给候选更换工具流程。', '',
        '实际工艺库和SDC不变：ASAP7 RVT TT、理想时钟、无提取寄生、2 ns目标、0.05 ns不确定度、0.2 ns最大/0 ns最小接口延迟、5 fF输出负载。20 ps为额外hold验收目标，不通过放宽SDC或Liberty获得。面积包括官方FakeRAM估计。四配置改变FE/BE/PHYS/ROB，RS容量保持INT=8、MUL/DIV=4；额外大站单元测试不等同于大站PPA证据。', '',
        '## 完整结果', '',
        '| 配置 | 版本 | IPC | 频率MHz | 总面积µm² | 频率变化 | 面积变化 | MIPS/面积变化 | 最小hold ps | cap/slew/hold违例 |',
        '|---|---|---:|---:|---:|---:|---:|---:|---:|---|']
    for r in rows:
        d = r['delta_percent']
        lines.append(f"| {r['config']} | {labels[r['variant']]} | {r['ipc_geomean']:.6f} | {r['fmax_mhz']:.2f} | {r['area_um2']:.2f} | {d['fmax_mhz']:+.2f}% | {d['area_um2']:+.2f}% | {d['mips_per_1000um2']:+.2f}% | {r['min_hold_ps']:.3f} | {r['cap_pins']}/{r['slew_pins']}/{r['hold_endpoints']} |")
    lines += ['', '所有百分比均对同配置、同流程和同20 ps目标的本轮基线计算。IPC固定10周期内存延迟，六项官方程序等权几何平均；MIPS=IPC×频率，仅代表该模型下的估计吞吐。上一轮非负hold的数值仅保存在JSON中作历史定位，不与本表直接混算结构增益。', '',
        '同一个前轮组合RTL、同20 ps hold目标在两种工具流程下的基线如下，用于单独观察流程影响：', '',
        '| 配置 | 原流程20 ps MHz | 统一快速流程20 ps MHz | 原流程面积µm² | 统一快速流程面积µm² |',
        '|---|---:|---:|---:|---:|']
    for r in rows:
        if r['variant'] == 'baseline':
            lines.append(f"| {r['config']} | {r['legacy_20ps_fmax_mhz']:.2f} | {r['fmax_mhz']:.2f} | {r['legacy_20ps_area_um2']:.2f} | {r['area_um2']:.2f} |")
    lines += ['',
        '## 关键路径与电气修复', '',
        '| 配置 | 版本 | 原cap引脚 | 原slew引脚 | 修复前低于20 ps端点 | 最长路径组合级数 | 其中BUF/INV级数 | 到达时间ns |',
        '|---|---|---:|---:|---:|---:|---:|---:|']
    for r in rows:
        p = r['critical_path']
        lines.append(f"| {r['config']} | {labels[r['variant']]} | {r['raw_cap_pins']} | {r['raw_slew_pins']} | {r['hold_below_target_before']} | {p['combinational_stages']} | {p['buffer_inverter_stages']} | {p['arrival_ns']:.3f} |")
    lines += ['', '4×4关键路径的状态名通过重放同一综合脚本至dfflibmap、在ABC/清理前保留名称，并按原状态单元名及类型对齐恢复：', '',
              '| 版本 | 起点状态Q别名 | 终点寄存器Q别名（其D为路径终点） |', '|---|---|---|']
    for info in result['state_provenance_4x4']:
        points = info['points']
        lines.append('| '+labels[info['variant']]+' | '+', '.join('`'+a+'`' for a in points['start']['state_output_aliases'])+
                     ' | '+', '.join('`'+a+'`' for a in points['end']['state_output_aliases'])+' |')
    lines += ['',
        '路径级数按OpenSTA同一单元输入→输出弧计数，包含缓冲和反相器，不是流水级数。原综合清除的RTL网络来源不会被推测为确定模块归属；每条路径起止状态、最大延迟级、负载、转换时间和可用src属性保存在JSON。', '',
        '沿用上一轮高扇出缓冲、驱动尺寸调整及真实cap/slew收敛。所有版本从各自hold填充前的电气修复网表出发，对所有低于20 ps的路径修复，而不只处理负slack。每次重建保持全部原FF/SRAM/tie单元、时钟和接口连接，执行全组合边界CEC，并复查setup、cap/slew、hold。Liberty逐库逐引脚限制保持原样；未设置最大fanout约束时不声称fanout签核通过。', '',
        f"本轮ABC尺寸调整日志中最长累计迭代时间为{max(r['sizing_max_logged_seconds'] for r in rows):.2f}秒，参数预算为30秒。PPA仍为每配置一次脚本映射/修复的点估计，不提供布局种子或工艺角统计范围。", '',
        '## 结构、顺序与接线', '',
        '`rv32_ranked_select`以有效位、年龄、打包数据、锁定端口和锁定槽号为输入。所有锁定槽先从新候选中排除；逐候选并行比较谁更老，以平衡加法树求rank。未锁定端口按其在未锁定端口中的序号匹配rank，锁定端口保留槽位。one-hot mask驱动平衡OR树，归并数据及槽号。相同年龄按较小槽号优先。比较器数量O(N²)，本表面积反映其代价。', '',
        '写回将轮询起点到每个源的循环距离作为年龄，源缓冲的tag/value/control/exception信息整体打包，保持完成通道顺序和原轮询更新规则。INT/MDU RS沿用rob_distance；唤醒广播优先级、锁定背压、原顺序状态更新和当拍腾槽切断保持不变。没有修改rename、ROB、cache、LSQ或MMIO协议。', '',
        '代码中存在以下同拍结构依赖；起止寄存器由前面的重放结果确认，具体关键门级路径以STA记录为准：', '',
        '```mermaid', 'flowchart LR',
        '  RR["RR state Q"] --> P["Completion packing"] --> R["ROB accept / phys lookup"]',
        '  R --> W["Writeback broadcast"] --> U["RS wakeup"] --> S["RS select"]',
        '  S --> M["issue_remove_mask"] --> D["RS state D: clear / update"]',
        '```', '',
        '## 验证', '',
        '三个候选分别通过186条单元PASS；每个候选完整81参数矩阵、381项检查及207次功能运行，合计1143项检查和621次功能运行。四配置每候选19正确性+6官方性能+6微基准，共300次官方、72次微基准；性能计数守恒通过且372项周期与前轮组合逐项相同。Verilog源按2005标准检查，FakeRAM使用原框架SV接口。', '',
        '四配置分别对写回、INT RS、乘法MDU核心及除法MDU核心作16组任意状态边界CEC：匹配所有原状态Q位和时钟，把原Q视为共享任意输入，把每个D及顶层输出作为比较输出。不只依靠有限拍或归纳后的观察点匹配。新选择器另有21配置/21000次独立顺序参考随机事务，五项负向控制验证错误时钟、遗漏状态、逻辑破坏、空裕量报告和截断报告均不能产生PASS。物理修复各阶段CEC日志逐一校验。', '',
        '初始化阶段发现并修复了测试Makefile的库文件接入、SOURCE_COUNT=1零宽槽号，以及年龄表达式的隐式截断警告；最终冻结快照重新运行完整检查，没有修改正式测试或放宽严格lint。早期失败日志独立保留。', '',
        '频率是布局前最小周期搜索估计，2 ns下的setup slack逐项保存在JSON；电气和20 ps hold通过不代表2 ns setup通过。没有布局、CTS、RC提取、多PVT/OCV或门级SDF验证。名义20 ps裕量较上一轮接近0的结果更稳健，但不能据此宣称物理签核。', '',
        '## 下一步取舍', '']
    for name, r in best.items():
        lines.append(f"- {name}：本轮估计MIPS最高为{labels[r['variant']]}，{r['estimated_mips']:.2f} MIPS，面积效率{r['mips_per_1000um2']:.3f} MIPS/1000µm²。结合面积表选择候选，避免只按宽度或IPC排名。")
    lines += ['',
        '优先检查RS的状态更新扇出：正式INT RS在issue_remove时将ready、值、物理号等全部清零（rv32_integer_reservation_station.v:752起），MDU也有同样分支。因此写回轮询→广播唤醒→选择→issue_remove还控制大量payload寄存器的D。可另做“无效条目payload保留、只切换busy/valid”的隔离实验，减少清零扇出；这不是本轮已实现内容。必须证明空闲payload不可观察、锁定槽始终有效、重分配覆盖完整字段，并用状态抽象等价和回归验证，不能直接沿用本轮逐D完全相等的证明或删除恢复/错误处理。', '',
        '再按恢复的路径分解写回轮询编码、ROB完成查询、rename/派发容量前缀和局部ready归并；需要时独立试验直接循环年龄比较、树形前缀或流水切分，并重新测IPC代价。Store队头等待和取指供给仍是独立IPC问题，本轮没有通过更改提交/MMIO/错误语义换取周期收益。正式集成前须在可稳定复现的综合流程、多角及布局后环境复测。', '',
        f"完整原始证据：`{OUT}`。复现：[README]({EXP/'README.md'})；结构化结果：[results-summary.json]({EXP/'results-summary.json'})。", '',
        '本轮仅新增隔离实验与报告；正式RTL与SORA不变，不推送，既有用户修改保留。', '']
    (ROOT/'docs/round4-tree-optimization.md').write_text('\n'.join(lines))


if __name__ == '__main__':
    main()
