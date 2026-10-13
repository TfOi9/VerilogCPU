#!/usr/bin/env python3
"""Join validated simulation, regression, synthesis and electrical evidence."""
import json
import math
from pathlib import Path
from setup import ROOT, EXP, OUT, VARIANTS, CONFIGS, digest, verify

PERF = ('median','multiply','qsort','rsort','towers','vvadd')
MICRO = ('dependent-add','independent-add','hot-load','hot-store','rs-pressure','mdu-pressure')

def read(path):
    return json.loads(path.read_text())

def geometric(values):
    values = list(values)
    return math.exp(sum(math.log(x) for x in values)/len(values))

def delta(value, baseline):
    return (value/baseline-1)*100

def main():
    manifest = verify()
    previous = read(ROOT/'reports/performance.json')
    previous_synth = read(ROOT/'reports/synthesis-matrix.json')
    previous_main_synth = read(ROOT/'reports/bus-pipeline-synth-after-2x2.json')
    baseline_cases = {tuple(r[k] for k in ('FE_WIDTH','BE_WIDTH','PHYS_REGS','ROB_ENTRIES')):r['cases'] for r in previous['results']}
    historical_synth = {tuple(r[k] for k in ('FE_WIDTH','BE_WIDTH','PHYS_REGS','ROB_ENTRIES')):r['report'] for r in previous_synth['results']+previous_main_synth['results'] if r['mode']=='opt'}
    correctness = sorted(p.name for p in (ROOT.parent/'RISC-V-CPU-2026-Testcases').glob('correctness_*'))
    rows, regressions = [], []
    artifacts = {str(OUT/'manifest.json'):digest(OUT/'manifest.json')}
    checked_hashes = {}
    def check_hashes(hashes):
        for filename, expected in hashes.items():
            if filename not in checked_hashes:
                checked_hashes[filename] = digest(Path(filename))
            assert checked_hashes[filename] == expected, ('stale evidence input',filename)
    guard_log = OUT/'checks-unit.log'
    guard_text = guard_log.read_text()
    assert 'Ran 7 tests' in guard_text and guard_text.rstrip().endswith('OK')
    artifacts[str(guard_log)] = digest(guard_log)
    for variant in VARIANTS:
        base = OUT/variant
        unit, matrix = read(base/'unit.json'), read(base/'matrix.json')
        directed = read(base/'directed/results.json')
        assert unit['passed'] and matrix['completed'] and matrix['passed'] and matrix['sources_unchanged']
        check_hashes(matrix['source_sha256'])
        assert len(matrix['matrix'])==81 and len(matrix['functional'])==9
        assert len(directed)==3 and all(r['passed'] for r in directed)
        for r in matrix['functional']:
            assert r['completed'] and r['passed'] and all(x['passed'] for x in r['results'])
        regressions.append({'variant':variant,'unit_pass_lines':unit['pass_lines'], 'matrix_configs':len(matrix['matrix']),
            'matrix_checks':len(matrix['checks']),'matrix_functional_runs':sum(len(r['results']) for r in matrix['functional']),
            'lsq_response_boundary_runs':len(directed),'passed':True})
        for p in (base/'unit.json',base/'matrix.json',base/'directed/results.json'):
            artifacts[str(p)] = digest(p)
    for config in CONFIGS:
        name = '{}x{}-p{}-r{}'.format(*config)
        for variant in VARIANTS:
            sim_dir = OUT/variant/'sim'/name
            sim_hash = digest(sim_dir/'sim')
            check_hashes(read(sim_dir/'sources.json'))
            cases = {}
            for case in correctness + ['perf_'+p for p in PERF] + list(MICRO):
                p = sim_dir/(case+'.json')
                r = read(p)
                assert r['passed'] and all(r['checks'].values())
                assert r['profile']['counts']['cache_mmio_requests']==1
                assert r['sim_sha256']==sim_hash and r['profile']['counts']['counter_schema_version']==2, (variant,name,case,'stale simulator/profile')
                cases[case] = r
                artifacts[str(p)] = digest(p)
            p = OUT/variant/'synth'/(name+'.json')
            synth = read(p)
            assert synth['completed'] and synth['passed'] and synth['sources_unchanged']
            check_hashes(synth['source_sha256'])
            r = synth['results'][0]['report']
            electrical_path = OUT/variant/'synth'/name/'electrical/report.json'
            electrical = read(electrical_path)
            assert electrical['completed']
            check_hashes(electrical['input_sha256'])
            path_audit = OUT/variant/'synth'/name/'path-audit.json'
            paths = read(path_audit)
            check_hashes(paths['artifact_sha256'])
            artifacts.update({str(p):digest(p),str(electrical_path):digest(electrical_path),str(path_audit):digest(path_audit)})
            perf = {key:cases['perf_'+key] for key in PERF}
            ipc = geometric(x['ipc'] for x in perf.values())
            fmax, area = r['timing']['estimated_fmax_mhz'], r['area']['area_um2']
            row = {'variant':variant,'config':name,'ipc_geomean':ipc,'fmax_mhz':fmax,'area_um2':area,
                   'logic_area_um2':r['area']['logic_area_um2'],'sram_area_um2':r['area']['sram_area_um2'],
                   'estimated_mips':ipc*fmax,'estimated_mips_per_1000um2':ipc*fmax/area*1000,
                   'minimum_period_ns':r['timing']['minimum_period_ns'], 'electrical_pass':electrical['electrical_pass'],
                   'cap_violating_pins':electrical['max_capacitance']['violating_pins'],
                   'slew_violating_pins':electrical['max_slew']['violating_pins'],
                   'worst_cap':electrical['max_capacitance']['worst_slack'],
                   'worst_slew':electrical['max_slew']['worst_slack'],
                   'max_fanout_status':electrical['max_fanout_status'],
                   'official_cases_passed':len(correctness)+6,'micro_cases_passed':len(MICRO),
                   'official_cycles':{k:cases[k]['cycles'] for k in correctness+['perf_'+p for p in PERF]},
                   'perf_cycles':{k:v['cycles'] for k,v in perf.items()},
                   'perf_counts':{k:v['profile']['counts'] for k,v in perf.items()},
                   'micro_cycles':{k:cases[k]['cycles'] for k in MICRO},
                   'micro_counts':{k:cases[k]['profile']['counts'] for k in MICRO},
                   'hot_load_request_gap':cases['hot-load']['profile']['histograms']['lsq_request_gap'],
                   'critical_path':paths['checks'][0]}
            if variant=='baseline':
                assert all(row['perf_cycles'][x['name'][5:]]==x['cycles'] for x in baseline_cases[config])
                old = historical_synth[config]
                row['matches_previous_cycles'] = True
                row['matches_previous_ppa'] = area==old['area']['area_um2'] and fmax==old['timing']['estimated_fmax_mhz']
            rows.append(row)
        base = rows[-3]
        for row in rows[-3:]:
            row['delta_percent'] = {key:delta(row[key],base[key]) for key in ('ipc_geomean','fmax_mhz','area_um2','estimated_mips','estimated_mips_per_1000um2')}
            row['official_cycles_equal_to_baseline'] = sum(n==base['official_cycles'][k] for k,n in row['official_cycles'].items())
        assert rows[-1]['official_cycles_equal_to_baseline'] == len(base['official_cycles'])
        assert rows[-1]['micro_cycles'] == base['micro_cycles']
    result = {'completed':True,'regression_passed':True,'electrical_pass':all(r['electrical_pass'] for r in rows),
              'baseline_head':manifest['head'],'production_and_sora_unchanged':True,
              'observation_failure_gate_tests_passed':7,
              'configs':len(CONFIGS),'variants':list(VARIANTS),'counter_schema_version':2,
              'regressions':regressions,'rows':rows,'artifact_sha256':artifacts,
              'experiment_tool_sha256':{str(p):digest(p) for p in sorted(EXP.iterdir()) if p.suffix in ('.py','.h','.vh')},
              'experimental_rtl_sha256':manifest['variants']}
    (EXP/'results-summary.json').write_text(json.dumps(result,indent=2)+'\n')
    write_report(result)
    print('Validated report written. Electrical qualification:',result['electrical_pass'])

def write_report(result):
    rows = result['rows']
    main = rows[:3]
    lines = ['# 第二轮性能隔离实验报告', '',
             '基线：`'+result['baseline_head']+'`。三组实验均由正式版独立复制；正式 RTL、SORA 与既有报告保持不变。', '',
             '## 结论', '',
             'RS 切断的频率收益没有跨配置一致保持。主配置 2×2 收益明显，但 1×1 退化；四配置应分别决定是否采用，不能统一宣称提升。LSQ 消泡稳定改善访存周期，但估计总吞吐还受综合后的频率变化影响。全部配置的电气门禁仍未通过，高扇出与约束收敛应先于大规模扩宽或容量扩容。', '',
             '## 对比结果', '',
             'IPC 为六个官方性能程序的等权几何平均，外存模型固定为 10 个周期。频率与面积均为本轮重新运行的同一官方 ASAP7 opt 流程。MIPS 是该模型下的 IPC×估计 Fmax；若改为固定纳秒的外存延迟，需重新测 IPC。所有电气门禁需另看下表。', '',
             '| 配置 | 版本 | IPC | Fmax MHz | 总面积 µm² | 估计 MIPS | MIPS 变化 | 面积变化 |',
             '|---|---|---:|---:|---:|---:|---:|---:|']
    for r in rows:
        d=r['delta_percent']
        lines.append(f"| {r['config']} | {r['variant']} | {r['ipc_geomean']:.6f} | {r['fmax_mhz']:.3f} | {r['area_um2']:.2f} | {r['estimated_mips']:.4f} | {d['estimated_mips']:+.2f}% | {d['area_um2']:+.2f}% |")
    lines += ['', '| 配置 | RS 频率变化 | RS 面积效率变化 | LSQ IPC 变化 | LSQ 频率变化 | LSQ 面积效率变化 |', '|---|---:|---:|---:|---:|---:|']
    for i in range(0,len(rows),3):
        base,lsq,rs=rows[i:i+3]
        a,b=lsq['delta_percent'],rs['delta_percent']
        lines.append(f"| {base['config']} | {b['fmax_mhz']:+.2f}% | {b['estimated_mips_per_1000um2']:+.2f}% | {a['ipc_geomean']:+.2f}% | {a['fmax_mhz']:+.2f}% | {a['estimated_mips_per_1000um2']:+.2f}% |")
    lines += ['', '面积效率指估计 MIPS/面积。这里分别重新综合每个实验，并未把 LSQ 与 RS 改动叠加；组合结果不能由两项百分比直接相乘推算。四个选点的 PRF/ROB 容量也不同，因此跨选点差异不能单独归因于 FE/BE 宽度；每一选点内的 baseline/LSQ/RS 对照才是单因素实验。']
    best=max(rows,key=lambda r:r['estimated_mips'])
    efficient=max(rows,key=lambda r:r['estimated_mips_per_1000um2'])
    lines += ['', f"这四个选点中，估计吞吐最高的是 {best['config']} 的 {best['variant']}（{best['estimated_mips']:.4f} MIPS）；估计面积效率最高的是 {efficient['config']} 的 {efficient['variant']}（{efficient['estimated_mips_per_1000um2']:.4f} MIPS/千 µm²）。这仍受下面的电气证据边界限制。"]
    lines += ['', '## 主配置的逐项周期', '', '| 程序 | baseline | LSQ 消泡 | RS 切断 | LSQ 周期降低 |', '|---|---:|---:|---:|---:|']
    for case in PERF:
        a,b,c=[r['perf_cycles'][case] for r in main]
        lines.append(f'| {case} | {a} | {b} | {c} | {(1-b/a)*100:.2f}% |')
    lines += ['', '## 电气约束', '',
              '每次审计使用该次综合实际映射网表、Liberty、原始 SDC。转换时间按受约束引脚计数，同一慢驱动的负载会分别计数；不能将引脚数当作独立慢网数。', '',
              '| 配置 | 版本 | 最大电容违例引脚 | 最大转换时间违例引脚 | 电气通过 |', '|---|---|---:|---:|---|']
    for r in rows:
        lines.append(f"| {r['config']} | {r['variant']} | {r['cap_violating_pins']} | {r['slew_violating_pins']} | {'是' if r['electrical_pass'] else '否'} |")
    lines += ['', '| 配置 | 版本 | 最坏电容 actual/limit fF | 电容超限倍数 | 最坏转换时间 actual/limit ns | 转换时间超限倍数 |', '|---|---|---:|---:|---:|---:|']
    for r in rows:
        cap,slew=r['worst_cap'],r['worst_slew']
        lines.append(f"| {r['config']} | {r['variant']} | {cap['actual']:.2f}/{cap['limit']:.2f} | {cap['ratio']:.2f}× | {slew['actual']:.3f}/{slew['limit']:.3f} | {slew['ratio']:.2f}× |")
    lines += ['', '最坏值表按最负 slack 选择引脚，倍数为该引脚的 actual/limit，不等同于全局最大归一化倍数。该流程没有最大 fanout 约束，记为未约束。ASAP7 的库级默认转换时间限制为 4 ns，但不少单元输入引脚有更严格的 0.32 ns 限制，审计使用实际引脚限制。', '',
              '频率为布局前、理想时钟、无提取互连寄生的估计。严重电气违例可能使 NLDM 在查表范围之外外推；因此上面的频率和 MIPS 用于同流程隔离比较，不能作为物理实现可达频率承诺。SRAM 包含官方 FakeRAM 面积估计。', '',
              '减少电气违例数量不等于最坏违例减轻。例如 4×1 的 RS 版本违例引脚总数减少，但最坏电容从 856.55 fF 增至 932.60 fF（限制 23.04 fF），最坏转换时间从 16.64 ns 增至 21.42 ns（限制 0.32 ns）。2×2 RS 的最坏电气程度减轻，但违例引脚数量反而增加。', '',
              '## 关键路径解释', '', '| 配置 | 版本 | 起点模块 | 终点模块 | 最大单级延迟 ns | 该级扇出 | 该级电容 fF |', '|---|---|---|---|---:|---:|---:|']
    for r in rows:
        p=r['critical_path'];s=p['largest_stages'][0]
        start=p['start']['attributes'].get('src','').split('/input/')[-1].split(':')[0] or '无 RTL src：'+p['start']['pin']
        end=p['end']['attributes'].get('src','').split('/input/')[-1].split(':')[0] or '无 RTL src：'+p['end']['pin']
        lines.append(f"| {r['config']} | {r['variant']} | {start} | {end} | {s['delay_ns']:.3f} | {s['fanout']} | {s['cap_ff']:.2f} |")
    lines += ['', '2×2 RS 版本削弱了原有写回到 RS/乘法器的长组合路径；1×1 则转为 Fetch→MDU RS 路径主导，频率下降。4×1 RS 的最大单级延迟仍超过 20 ns、扇出达到 1842，说明切断一条逻辑依赖并未解决全局高扇出。', '',
              'LSQ 修改后主配置最坏路径仍从写回网络出发、落在 INT RS，并不是 LSQ 本身成为最坏端点。其频率下降是本次完整映射的实测结果，不能仅凭该百分比断言新增 LSQ 条件就是关键路径根因。应在电气修复后重复对照，检查路径是否稳定。', '',
              '## 微基准与因果验证', '', '| 微基准，2×2 | baseline | LSQ 消泡 | RS 切断 |', '|---|---:|---:|---:|']
    for case in MICRO:
        a,b,c=[r['micro_cycles'][case] for r in main]
        lines.append(f'| {case} | {a} | {b} | {c} |')
    lines += ['', 'LSQ 的请求/响应配对仍保持单笔在途。hot-load 的主导请求间隔从 6 拍变为 5 拍；这项修改消去的是请求调度空泡，不增加 cache 的 outstanding 数量，也不改变 miss 处理能力。', '',
              'RS 的关键发现：`rv32_decode_rename_dispatch.v` 的前缀筛选先按拍前 occupancy 限制每类 RS 的派发数量，因此整机本来就不会将当拍腾出的槽计入容量。INT/MDU RS 内的 `issue_remove_mask_reg → available_slot_mask_reg → dispatch_ready` 依赖没有实现整机同拍腾槽吞吐收益。两个满队列压力程序明确覆盖这一情形，架构周期比较与随机参考模型共同验证了切断实验。', '',
              '四个配置各自的全部 25 个官方程序及 6 个微基准，RS 版本与基线的周期数逐项相同；频率变化来自组合逻辑和完整映射变化，而非减少执行周期。', '',
              '前缀筛选处的容量阻塞与筛选后的 ready 阻塞分别计数。多个资源可同时不足，重叠计数不相加；详细计数、Store 队头阶段和各延迟直方图见原始 JSON。', '',
              '2×2 压力程序中，INT RS 的容量筛选阻塞为 30,969 拍，其中 999 拍当拍本有释放槽；MDU 对应为 35,981 拍和 4,997 拍。基线与 RS 实验周期仍相同，证明这部分潜在复用已经被前级筛选抑制。', '',
              '## 剩余 IPC 瓶颈', '', '| 程序，2×2 | 基线 Store 队头等待占比 | LSQ 版 Store 队头等待占比 | 基线非恢复 Fetch 空占比 | LSQ 版非恢复 Fetch 空占比 |', '|---|---:|---:|---:|---:|']
    for case in PERF:
        a,b=main[0],main[1]
        ca,cb=a['perf_counts'][case],b['perf_counts'][case]
        wait=lambda c:sum(v for k,v in c.items() if k.startswith('store_head_phase_'))/c['cycles']*100
        lines.append(f"| {case} | {wait(ca):.2f}% | {wait(cb):.2f}% | {ca['fetch_empty_not_recovery']/ca['cycles']*100:.2f}% | {cb['fetch_empty_not_recovery']/cb['cycles']*100:.2f}% |")
    lines += ['', 'Store 队头等待与 Fetch 空是重叠观察窗口，不能相加成总损失。LSQ 消泡只改善其中部分等待；Store 仍在 ROB 头部才发出、等待响应后退休，且 D-cache miss 会阻塞后续请求。multiply 的前端空窗应另做分支/取指定位，队列为空的相关性本身不能区分预测、I-cache miss 与正常供给节奏。', '',
              'Store 在途子阶段使用 D-cache RUN/非 RUN 状态作代理分类；MMIO 旁路可能落入 RUN，不能据此推算 MMIO 专用耗时。array_commit 延迟只覆盖命中 Store，不含 Store miss 的合并 refill 写入。所有程序均检查只有一笔结束 MMIO 请求；它的未退休状态单独保留。详细口径见 README。', '',
              '## 回归与证据', '']
    for r in result['regressions']:
        lines.append(f"- {r['variant']}：完整 unit 套件 {r['unit_pass_lines']} 条 PASS；{r['matrix_configs']} 个参数组合、{r['matrix_checks']} 项矩阵检查、{r['matrix_functional_runs']} 次功能运行；3 个 BE 宽度的 LSQ 响应边界扩展用例全部通过。")
    lines += ['', f"四个配置 × 三个版本：{sum(r['official_cases_passed'] for r in rows)} 次官方程序、{sum(r['micro_cases_passed'] for r in rows)} 次微基准均通过，并通过计数守恒检查；12 次新综合完成。",
              '', '7 项观测失败门禁测试通过：覆盖计数丢失/重复、周期不守恒、电气报告截断/解析失败，以及工具返回成功但电气不合格的情况。',
              '', 'RS 最后一组矩阵在综合完成、资源空出后按更高宿主并发完整重跑，初始未完成记录另存；最终汇总只采用完整通过的一组。线程数不改变 CPU 参数、随机种子和检查规则。',
              '', '基线四配置的官方性能周期与上轮正式报告逐项一致。PPA 重现结果：'+', '.join(r['config']+'='+str(r['matches_previous_ppa']) for r in rows if r['variant']=='baseline')+'。', '',
              '初次 RS 单元测试暴露的是契约和测试适配问题：随机参考模型仍允许当拍复用，且新增定向用例暂时关掉的 MDU issue grant 未恢复。修正仅位于隔离测试副本/生成脚本；再次完整运行通过。原始失败日志保留，没有将进程返回 0 误判为 PASS。', '',
              f"复现说明：[README]({EXP/'README.md'})；结构化汇总：[results-summary.json]({EXP/'results-summary.json'})。",
              f"原始证据：`{OUT}`，包括快照/哈希、每条命令及超时、逐程序日志/计数、完整综合和电气报告。", '',
              '## 后续取舍', '',
              '优先按 IPC×频率与面积效率选择下一步，而不按 IPC 单项排序。RS 切断是否值得正式集成要结合四配置结果及电气收敛后的复测；LSQ 消泡的主配置 IPC 增益被本轮频率变化抵消，不能仅凭周期改善宣布总体性能提高。', '',
              '1. 先做同一网表的高扇出缓冲、驱动尺寸调整和实际引脚电气限制收敛实验。同时记录违例数量与最坏值，保留原始映射对照；不能通过放宽 Liberty 限制来获得 PASS。重点检查写回/派发公共控制与 Fetch→MDU RS 扇出。', '',
              '   结合本轮前缀容量检查的证据，可另立实验验证容量检查是否已蕴含各局部 ready，再缩短冗余的全局派发握手链并分散局部使能；需用断言/等价检查和回归证明，不直接删除握手保护。', '',
              '2. 在相同、已收敛的流程中重跑 baseline、LSQ、RS，并追加第四组 LSQ+RS 交互实验。2×2 RS 可作为候选，1×1 暂缓采用；只有组合回归、频率与面积效率均得到实测支持后，再讨论正式集成。', '',
              '3. 对 rsort/towers 的 Store 队头等待做独立的提交 Store buffer 实验，明确 store fault、MMIO 必须等待响应，以及转发和恢复规则。对热 Load 则测试 request queue/多笔在途；D-cache miss 阻塞需用独立 MSHR 或非阻塞 cache 实验定位，不能把命中吞吐收益外推为 miss 并行收益。', '',
              '4. 对 multiply 补充预测目标到首条有效取指、redirect 丢弃、Fetch 队列供给的分解。先降低空拍，再判断 FE/BE 扩宽、PRF/ROB 扩容是否有价值。上述进一步设计本轮均未实现。', '']
    (ROOT/'docs/round2-performance-20261013.md').write_text('\n'.join(lines))

if __name__ == '__main__':
    main()
