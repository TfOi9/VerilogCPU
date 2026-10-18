# 面积约束优化

结果见 [设计与测量报告](../../docs/area-optimization-20261018.md) 及 `results-summary.json`。本轮基线为 `bafa464`，所有分支提交均留在本地。

## 驱动与口径

- `measure.py` 冻结 RTL/header、配置投影、官方程序、框架、工具与 Liberty；`screen` 只跑六个性能程序，`suite` 跑完整 25 程序，`ppa` 调用未修改的官方 `opt` 流程。配置、日志、命令、模拟器及输入哈希都保存在指定的新目录，拒绝覆盖已有快照。
- `prepare_cache.py` 为 D-Cache 容量筛选生成显式投影。8 KiB 两路/四路均未通过 IPC 门槛，未采用。
- `prove_prf.py` 从原/新实际 PRF RTL 生成带逻辑状态观察端口的归纳证明；默认覆盖 33x1 和 56x2。`--wide` 额外尝试 96x4，仍受 120 秒单项超时约束。`--reuse` 只复用源码、生成模型、Yosys 命令与成功日志哈希完全匹配的已通过单项，不把未完成的父批次视为全部通过。
- `check_capacity.py` 检查 PRF56、恢复宽度 7 下的三个后端宽度，覆盖 24 项非二次幂空闲队列。
- `qualify_selected.py` 在 FE2/BE2、PRF56、ROB32、恢复宽度 7 下执行三个逐退休差分种子。
- `report.py` 审核完整官方程序、同流程 PPA、全参数矩阵、单元/lint、定向测试及源码，要求面积下降、IPC 均值/Fmax 各回退不超过 3%。输入不完整时拒绝生成成功汇总。

原始目录位于本工作树的 `build/area-codex-20261018/`：`reference` 为重跑的六程序基线，`final` 为最终选定配置，`final-matrix.json` 为本轮唯一完整参数矩阵。`valid-prf-fe2-d0-p56-r32` 是 16 项提示的频率不合格候选；`fallback-p64` 中的综合被主动中止，没有 PPA 结论。其余 `screen-results.json` 仅为六程序筛选，不代表完整验收。

更早的共享目录探针保留在原工作目录 `/Users/zhaoruicheng/Downloads/VerilogCPU/build/area-20261018/`，本工作树 `build/area-codex-20261018/screen-evidence/` 保存了其筛选结果副本。该早期探针未进入最终实现。

完整矩阵开始时和结束时核对同一份 RTL/测试驱动；优化不再扩展后只执行一轮矩阵。形式证明超时及早期测试驱动的 PASS 文本匹配错误都保留原始日志；后者已更正，实际 rename 测试本身通过，最终独立容量检查也通过。

## 复现单个配置

在仓库根目录运行。依赖沿用 `make synth-setup`；框架与测试仓库保持为相邻目录。每次使用新的 `--out`，不要覆盖归档。

```sh
python3 -B experiments/area_20261018/measure.py --phase prepare \
  --fe 2 --phys 56 --rob 32 --directory 0 --hints 8 \
  --out build/area-replay-final
timeout -k 5 900 python3 -B experiments/area_20261018/measure.py \
  --phase suite --out build/area-replay-final
timeout -k 5 1900 python3 -B experiments/area_20261018/measure.py \
  --phase ppa --out build/area-replay-final
make prf-reset-unit
```

基线源码可用 `git archive bafa464 rtl verilog` 导出到独立目录，再通过 `--source` 准备 FE4/BE2、PRF64、ROB32、256 项目录、16 项提示的快照。不能用新 PRF 实现搭配旧参数代替原 RTL 基线。

本轮完整验收入口如下；已有完整结果时无需重复执行这些高耗能步骤。

```sh
timeout -k 5 1800 make -j1 unit
timeout -k 5 900 make -j1 lint
timeout -k 5 3600 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 2 \
  --framework ../RISC-V-CPU-2026 --testcases ../RISC-V-CPU-2026-Testcases \
  --build-root build/area-codex-20261018/final-matrix \
  --report build/area-codex-20261018/final-matrix.json
```

`report.py` 面向本轮归档执行最终审计，需要 `baseline-ppa-audit.json`、`gates.json` 和 README 所列其他验证记录；它不自动重跑高耗能任务。
