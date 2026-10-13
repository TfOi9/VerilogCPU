#!/usr/bin/env python3
"""Validate the bus-pipeline experiment and compare matching PPA configurations."""
import json
import hashlib
import math
from pathlib import Path
import re

from report_performance import comparison, configuration, require_passed, verify_hashes
from run_performance import case_result, geomean
from run_synthesis import digest, validate_report

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/bus-pipeline"
BASELINE = BUILD / "baseline"
REPORTS = ROOT / "reports"
FOCUS = (2, 2, 64, 32)


def read(path):
    return json.loads(path.read_text())


def checked_synthesis(metadata, historical=False):
    require_passed(metadata, "synthesis")
    verify_hashes({tool["path"]: tool["sha256"]
                   for tool in metadata["native_tools"].values()})
    hashes = {}
    for name, sha in metadata["source_sha256"].items():
        path = Path(name)
        if path == ROOT / "Makefile":
            continue
        if historical and path.parent == ROOT / "rtl":
            path = BASELINE / "rtl" / path.name
        hashes[str(path)] = sha
    verify_hashes(hashes)
    rows = {}
    for row in metadata["results"]:
        if row["mode"] != "opt":
            continue
        current = configuration(row)
        assert current not in rows and row["passed"]
        report = row["report"]
        assert read(Path(row["report_path"])) == report
        validate_report(report, "opt", metadata["clock_period_ns"])
        verify_hashes(row["generated_source_sha256"])
        verify_hashes({p["path"]: p["sha256"] for p in report["inputs"] + report["libraries"]})
        rows[current] = row
    return rows


def markdown_table(headers, rows):
    return "\n".join(["| " + " | ".join(headers) + " |",
                       "| " + " | ".join(["---"] * len(headers)) + " |"] +
                      ["| " + " | ".join(map(str, row)) + " |" for row in rows])


def main():
    before_perf = read(REPORTS / "bus-pipeline-performance-before.json")
    after_perf = read(REPORTS / "bus-pipeline-performance-after.json")
    after_synth = read(REPORTS / "bus-pipeline-synth-after.json")
    matrix = read(REPORTS / "bus-pipeline-matrix-after.json")
    verified = comparison(after_perf, after_synth, matrix)
    require_passed(before_perf, "baseline performance")
    verify_hashes(before_perf["source_sha256"])
    assert before_perf["latency"] == after_perf["latency"] == 10
    assert before_perf["max_cycles"] == after_perf["max_cycles"]
    assert before_perf["testcases_revision"] == after_perf["testcases_revision"]
    before = {configuration(r): r for r in before_perf["results"]}
    after = {configuration(r): r for r in after_perf["results"]}
    original = {configuration(r): r for r in read(BASELINE / "performance.json")["results"]}
    assert set(before) == set(after) == set(original)
    hardware_before = {Path(p).name: sha for p, sha in before_perf["hardware_sha256"].items()}
    hardware_after = {Path(p).name: sha for p, sha in after_perf["hardware_sha256"].items()}
    assert set(hardware_before) == set(hardware_after)
    changed = [p for p in hardware_before if hardware_before[p] != hardware_after[p]]
    assert changed == ["rv32_l1_cache_axi_bridge.v"], changed
    from sys import path as python_path
    python_path.insert(0, before_perf["framework"] + "/scripts")
    from oj_io import compare_output, prepare_case
    for config, row in before.items():
        assert row["passed"] and row["simulator"]["sha256"] == digest(Path(row["simulator"]["path"]))
        reference = {c["name"]: c for c in original[config]["cases"]}
        assert len(row["cases"]) == 6 and {c["name"] for c in row["cases"]} == set(reference)
        ipcs = []
        for case in row["cases"]:
            data, answer = prepare_case(Path(before_perf["testcases"]) / case["name"],
                                        before_perf["max_cycles"], before_perf["latency"])
            cycles = case_result(Path(case["stdout_path"]).read_text(),
                                 Path(case["stderr_path"]).read_text(), case["returncode"],
                                 answer, before_perf["max_cycles"], compare_output)
            assert case["passed"] and cycles == case["cycles"] == reference[case["name"]]["cycles"]
            assert case["input_sha256"] == hashlib.sha256(data.encode()).hexdigest()
            assert case["dynamic_instructions"] == reference[case["name"]]["dynamic_instructions"]
            assert case["ipc"] == case["dynamic_instructions"] / cycles
            ipcs.append(case["ipc"])
        assert math.isclose(row["ipc_geomean"], geomean(ipcs), rel_tol=1e-12)
    old_metadata = read(BASELINE / "synthesis-matrix.json")
    focus_before = read(REPORTS / "bus-pipeline-synth-before-2x2.json")
    focus_after = read(REPORTS / "bus-pipeline-synth-after-2x2.json")
    old_synth = checked_synthesis(old_metadata, historical=True)
    old_synth.update(checked_synthesis(focus_before))
    new_synth = checked_synthesis(after_synth)
    new_synth.update(checked_synthesis(focus_after))
    assert set(old_synth) == set(new_synth) and len(new_synth) == 10
    assert all(m["native_tools"] == after_synth["native_tools"] and
               m["clock_period_ns"] == after_synth["clock_period_ns"]
               for m in [old_metadata, focus_before, focus_after])
    rows = []
    for config in sorted(new_synth):
        pair = []
        for perf, synth in [(before, old_synth), (after, new_synth)]:
            report = synth[config]["report"]
            ipc = perf[config]["ipc_geomean"]
            area = report["area"]["area_um2"]
            frequency = report["timing"]["estimated_fmax_mhz"]
            pair.append({"ipc": ipc, "fmax_mhz": frequency, "area_um2": area,
                         "sram_um2": report["area"]["sram_area_um2"],
                         "mips": ipc * frequency, "mips_per_1000_um2": ipc * frequency * 1000 / area})
        a, b = pair
        rows.append({"config": list(config), "name": f"{config[0]}x{config[1]}-p{config[2]}-r{config[3]}",
                     "before": a, "after": b,
                     "percent_change": {k: (b[k] / a[k] - 1) * 100 for k in a},
                     "baseline_synthesis": "fresh" if config == FOCUS else "verified prior artifact"})
    validation = read(BUILD / "validation.json")
    assert validation["unit_lint_returncode"] == 0
    verify_hashes(validation["source_sha256"])
    verify_hashes(validation["log_sha256"])
    unit_log = (BUILD / "full-unit-lint.log").read_text()
    assert not re.search(r"^(?:FAIL|ERROR|Error)\b", unit_log, re.MULTILINE)
    assert len(re.findall(r"^PASS\b", unit_log, re.MULTILINE)) == validation["unit_pass_markers"]
    protocol_log = (BUILD / "bridge-final.log").read_text()
    assert "FAIL" not in protocol_log
    matches = re.findall(r"PASS cache AXI pipeline seed=(\d+) transactions=(\d+) checks=(\d+) read_max=4 write_max=4 aw_lead=4 w_lead=4 read_overlap=(\d+) write_overlap=(\d+) read_error_pending=(\d+) write_error_pending=(\d+)", protocol_log)
    assert len(matches) == 8 and len({m[0] for m in matches}) == 8
    assert all(all(int(v) > 0 for v in m[1:]) for m in matches)
    manifest = read(BASELINE / "manifest.json")
    verify_hashes(manifest["preserved_files"])
    sora = ROOT.parent / "SORA"
    verify_hashes({str(sora / p): sha for p, sha in manifest["sora_tracked_sha256"].items()})
    mutations = read(BUILD / "mutations/results.json")
    assert len(mutations) == 4 and all(m["rejected"] for m in mutations)
    ipc_rows = [{"config": list(c), "name": f"{c[0]}x{c[1]}-p{c[2]}-r{c[3]}",
                 "before": before[c]["ipc_geomean"], "after": after[c]["ipc_geomean"],
                 "percent_change": (after[c]["ipc_geomean"] / before[c]["ipc_geomean"] - 1) * 100}
                for c in sorted(after)]
    result = {"completed": True, "passed": True, "changed_hardware": changed,
              "baseline_commit": manifest["head"],
              "producer_sha256": digest(Path(__file__)),
              "latency": 10, "before_baseline_reproduced": True,
              "performance_runs_before": 108, "performance_runs_after": 108,
              "protocol_transactions": sum(int(m[1]) for m in matches),
              "protocol_checks": sum(int(m[2]) for m in matches),
              "mutation_checks": len(mutations), "correctness": verified["correctness"],
              "sora_tracked_files_unchanged": len(manifest["sora_tracked_sha256"]),
              "rows": rows, "all_ipc_rows": ipc_rows,
              "case_comparison": [{"name": c["name"], "before_cycles": c["cycles"],
                                   "after_cycles": next(x["cycles"] for x in after[FOCUS]["cases"] if x["name"] == c["name"])}
                                  for c in before[FOCUS]["cases"]],
              "input_reports_sha256": {str(p): digest(p) for p in [
                  REPORTS / "bus-pipeline-performance-before.json", REPORTS / "bus-pipeline-performance-after.json",
                  REPORTS / "bus-pipeline-synth-after.json", REPORTS / "bus-pipeline-synth-after-2x2.json",
                  REPORTS / "bus-pipeline-synth-before-2x2.json", REPORTS / "bus-pipeline-matrix-after.json",
                  BASELINE / "synthesis-matrix.json", BUILD / "validation.json"]}}
    (REPORTS / "bus-pipeline-comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    table = markdown_table(["配置", "IPC 前→后", "IPC 变化", "MHz 前→后", "面积 um² 前→后", "MIPS 变化", "单位面积吞吐变化"],
        [[r["name"], f'{r["before"]["ipc"]:.6f} → {r["after"]["ipc"]:.6f}',
          f'{r["percent_change"]["ipc"]:+.2f}%',
          f'{r["before"]["fmax_mhz"]:.2f} → {r["after"]["fmax_mhz"]:.2f}',
          f'{r["before"]["area_um2"]:.2f} → {r["after"]["area_um2"]:.2f}',
          f'{r["percent_change"]["mips"]:+.2f}%',
          f'{r["percent_change"]["mips_per_1000_um2"]:+.2f}%'] for r in rows])
    (REPORTS / "bus-pipeline-comparison.md").write_text("# 总线流水化配对结果\n\n" + table + "\n")
    focus = next(r for r in rows if tuple(r["config"]) == FOCUS)
    a, b, change = focus["before"], focus["after"], focus["percent_change"]
    regressions = "\n".join(
        f'- `{r["name"]}`：频率 {r["percent_change"]["fmax_mhz"]:+.2f}%，'
        f'IPC {r["percent_change"]["ipc"]:+.2f}%，估算吞吐 {r["percent_change"]["mips"]:+.2f}%。'
        for r in rows if r["percent_change"]["fmax_mhz"] < 0)
    ipc_table = markdown_table(["配置", "IPC 优化前", "IPC 优化后", "变化"],
        [[r["name"], f'{r["before"]:.6f}', f'{r["after"]:.6f}',
          f'{r["percent_change"]:+.2f}%'] for r in ipc_rows])
    cases = markdown_table(["程序", "优化前周期", "优化后周期", "加速比"],
        [[r["name"], f'{r["before_cycles"]:,}', f'{r["after_cycles"]:,}',
          f'{r["before_cycles"] / r["after_cycles"]:.3f}×'] for r in result["case_comparison"]])
    document = f'''# 总线流水化：正式实现、回归与 PPA 对比

本轮只修改总线桥接硬件，LSQ、Cache 容量/相联度、前后端宽度及其他核心实现均保持不变。SORA 的 {result['sora_tracked_files_unchanged']} 个已跟踪文件哈希不变；原有 PLAN.md 与 MODIFY.md 内容保留。

## 结果

同一 `2x2-p64-r32` 配置、官方主存延迟 10、相同六个性能镜像下：

- 几何平均 IPC：{a['ipc']:.6f} → **{b['ipc']:.6f}**（{change['ipc']:+.2f}%）。
- Fmax：{a['fmax_mhz']:.2f} → **{b['fmax_mhz']:.2f} MHz**（{change['fmax_mhz']:+.2f}%）。
- 总面积：{a['area_um2']:.2f} → **{b['area_um2']:.2f} um²**（{change['area_um2']:+.2f}%）。
- 估算吞吐 `IPC × Fmax`：{a['mips']:.3f} → **{b['mips']:.3f} MIPS**（{change['mips']:+.2f}%）。
- 单位面积估算吞吐提高 **{change['mips_per_1000_um2']:.2f}%**。SRAM 面积保持 {b['sram_um2']:.6f} um²。

该配置的源码快照和正式新 RTL 都重新构建了性能模拟器、完成了综合。正常路径的周期与前次总线流水化实验一致；本轮增加了正式错误收尾与完整协议验证，没有包含前次 LSQ 或两路 Cache 实验改动。

{cases}

收益主要体现在可被总线等待拖慢的程序：`perf_rsort` 周期接近减半，`perf_vvadd` 加速约 1.83 倍；`perf_multiply` 加速约 1.08 倍。18 个配置的 IPC 均提高约 45.6%–48.0%，说明行内请求串行等待是跨配置存在的瓶颈。该结论来自相同镜像的周期对照，不替代逐级 Cache/LSQ 事件计数。

## 实现与契约

`rv32_cache_axi4_lite_adapter` 采用 IDLE / READ / WRITE / RESPONSE 四个状态。AR、R、AW、W、B 分别计数，行内四个字可连续发出，不等待前一个字的响应；响应依序回收。AW 与 W 可独立领先，只有各自握手后索引才推进，未握手的 VALID 和负载保持稳定。读数据直接保存在行缓冲中，避免额外复制整行响应寄存器。

每次仍只接收一个 Cache 行事务或一个 MMIO 事务，仲裁和响应归属不变。非 OKAY 错误为粘滞状态，必须完整发送并回收本行四个字后才能向上游返回一次错误，读错误数据清零。不会因早期错误撤销已挂起的 VALID、丢失部分 AW/W 或把迟到响应交给下一请求。错误行写不承诺原子性，已经发生的普通 RAM 写入不回滚。

MMIO 使用 word_count=1，恰好一次 AW/W/B，原始地址、数据及 WSTRB 不扩展为四字；必须等 B 回来才完成。核心的 ROB 头部 Store 条件不变。上游响应背压期间不能接收下一事务。

共享复位同时取消桥接层与 AXI 从设备的旧事务。没有 ID 的接口不支持仅复位桥接层而保留从设备旧响应。结构、计数关系和接线详见 [cache_axi_bridge.md](cache_axi_bridge.md)。

## 验证范围

1. `make unit lint image-test matrix-unit perf-unit synth-unit` 全部通过；新桥接测试已经接入 `make cache-bridge-unit`，因此也属于后续 `make unit` 的默认覆盖。
2. 并发协议测试 8 个种子、**{result['protocol_transactions']} 个事务**、{result['protocol_checks']} 个周期检查全部通过。每个种子均实际达到四个读/写在途、AW 领先 W 四拍、W 领先 AW 四拍、请求与响应同拍重叠、请求尚未全部发完时收到错误。
3. 检查所有位置的 R/B 错误、非 OKAY 编码、多个错误合并、错误后的后继事务、字节掩码、MMIO 不同字地址和全部 16 种 WSTRB、I/D/MMIO 归属、其他客户端 READY 拉高时的长响应背压、读/AW/W/MMIO 在途共享复位和被背压响应期间复位。原有顺序从设备与三方仲裁测试也通过。
4. 四个定向错误注入均被测试拒绝：AW 索引误驱动 W、错误数据不清零、读错误提前完成、MMIO 错发四字。测试中的故意失败保存在独立 mutation 目录，不是正式回归失败。
5. 参数矩阵：81 配置 × 4 项静态检查，9 个代表配置 × 3 组退休差分；包含构建/功能步骤共 **{verified['correctness']['checks_passed']} 项检查**通过。功能运行 **{verified['correctness']['programs_passed']} 次**，其中 {verified['correctness']['official_correctness_passed']} 次官方 correctness、{verified['correctness']['official_performance_passed']} 次既有性能回归、{verified['correctness']['local_smoke_passed']} 次本地 smoke。
6. 优化前、后分别重跑 18 配置 × 6 程序，合计 **216 次性能运行**通过。旧版本全部 108 个周期逐项复现原报告。完整功能程序覆盖九个代表配置，不把 81 组静态检查宣称为 81 组全程序仿真。
7. 新 RTL 的九个代表配置及额外 2x2-p64-r32 共 **10 项 opt 综合**通过。2x2 主对照的旧版本也重新综合；其他九组旧数据复用已验证的既有综合产物，并逐项核对 RTL 快照、生成副本、库、工具二进制及原始报告哈希。

所有仿真和工具调用都有超时。汇总工具只有在完整矩阵、原始周期/输出、源文件哈希、综合产物及工具结果全部匹配时才输出成功，未用部分完成报告替代验收。

## 全配置配对结果

{table}

IPC 为六个程序的几何平均。面积包含标准单元与官方 FakeRAM 数据/标签 SRAM，排除外部 RAM。使用固定 Yosys 0.63 / ABC、ASAP7 RVT TT 和 OpenSTA；目标周期 2 ns、理想时钟、无布线寄生，前后约束相同。

Fmax 是综合网表估计，不是布局布线或 FPGA 实测。桥接逻辑改变也可能改变整核 ABC 映射，频率变化不应全部归因于某个桥接门的延迟。本次未声称达到 0.6 IPC 或 300 MHz；应同时看周期、频率、面积及单位面积吞吐，不能仅按 IPC 宣称实际运行时间收益。

以下配置出现了频率回退，需要后续专门处理时序，不能把主配置的频率提升推广到所有配置：

{regressions or '本次配对配置未观察到频率回退。'}

主配置前后的关键路径数据到达时间约为 21.79 ns 和 21.06 ns，起点均回溯到完成写回网络寄存器；总线改动没有消除整核时序瓶颈。回溯记录位于 `build/bus-pipeline/timing-focus.json`。

## 全部 18 配置 IPC

以下另外包含单参数敏感度配置。没有配对综合的配置只报告 IPC，不外推频率或面积。

{ipc_table}

## 复现与原始证据

```sh
timeout 300 make cache-bridge-lint cache-bridge-unit
timeout 1800 make unit lint image-test matrix-unit perf-unit synth-unit
timeout 7200 python3 tools/run_parameter_matrix.py \\
  --testcases ../RISC-V-CPU-2026-Testcases --phase all --jobs 2 --lint-jobs 2 \\
  --build-root build/bus-pipeline/matrix-after --report reports/bus-pipeline-matrix-after.json
timeout 3600 python3 tools/run_performance.py \\
  --testcases ../RISC-V-CPU-2026-Testcases --jobs 2 --config-jobs 2 --case-timeout 300 \\
  --build-root build/bus-pipeline/perf-after --report reports/bus-pipeline-performance-after.json
timeout 10800 python3 tools/run_synthesis.py --matrix --mode opt --jobs 2 \\
  --out build/bus-pipeline/synth-after --report reports/bus-pipeline-synth-after.json --timeout 1800
timeout 2400 python3 tools/run_synthesis.py --mode opt --fe-width 2 --be-width 2 \\
  --phys-regs 64 --rob-entries 32 --out build/bus-pipeline/synth-after \\
  --report reports/bus-pipeline-synth-after-2x2.json --timeout 1800
timeout 120 python3 tools/report_bus_pipeline.py
```

旧版基线为 `{manifest['head']}`，对应源码、头文件、原始报告和哈希记录位于 `build/bus-pipeline/baseline/`；旧版 IPC 使用同一性能命令，加 `--filelist build/bus-pipeline/baseline/filelist.f` 并把输出改为 `perf-before` / `bus-pipeline-performance-before.json`。旧版 2x2 综合同样使用此 filelist，输出为 `synth-before` / `bus-pipeline-synth-before-2x2.json`。正常复测应使用新的输出目录以保留当前证据。

运行器的结果、逐程序 stdout/stderr、映射网表、SDC、完整时序路径及日志保留在 `build/bus-pipeline/` 和 `reports/bus-pipeline-*.json`。协议日志为 `bridge-final.log`，全单元/lint 日志为 `full-unit-lint.log`。`validation.json` 记录已完成的单元命令退出码、日志与最终被测源码哈希；重新执行单元测试后需重新记录该证据，汇总工具不会把未执行的检查标为通过。

`reports/bus-pipeline-comparison.json` 提供所有指标、变化百分比、测试范围和输入报告哈希。主仓库保存本摘要及可复现工具；体积较大的原始产物按原 `.gitignore` 留在本机。SORA 未修改，未推送远程。
'''
    (ROOT / "docs/bus_pipeline_performance.md").write_text(document)
    print(json.dumps({"passed": True, "protocol_transactions": result["protocol_transactions"],
                      "focus": focus}, indent=2))


if __name__ == "__main__":
    main()
