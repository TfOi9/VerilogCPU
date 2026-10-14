# 仲裁树与恢复加宽实验

结论与完整结果见 [设计报告](../../docs/optimization-20261014.md)。正式改动为树化仲裁、INT/MDU RS 当拍槽位复用切断以及独立的 `RECOVERY_WIDTH=4`。Store 两个候选未集成；本目录保留其可重放补丁和定向测试。SORA 文件未修改。

## 文件与证据

| 文件 | 用途 |
| --- | --- |
| `run.py` | 冻结源文件，构建 FE=BE=2 的两种 Cache，运行三程序并校验恢复计数 |
| `profile.h` | 退休分类、分支事件、恢复长度和回滚深度统计；仅用于本目录的 2×2 实验 |
| `qualify.py` | 对已冻结且哈希一致的模拟器运行全部 25 个官方程序 |
| `probes.py` | 热 Store 与短交替分支微基准，独立指令解释器生成期望值 |
| `ppa.py` | 冻结 RTL 的映射、CEC、电气修复、20 ps hold 与 STA |
| `store-handoff.patch` / `store-yield.patch` | 未集成的 Store 实验，应用于树化+恢复加宽的 LSQ |
| `store_handoff_tb.v` | Store 候选的协议、错误、反压、回滚定向测试 |
| `report.py` | 汇总已完成的证据并检查当前源码哈希 |
| `results-summary.json` | 本次六项 IPC、三组 PPA、完整回归和被拒候选的已审核结果 |

本次原始输出根目录为 `build/optimization-20261014/`。`baseline-v2` 是 `74cd2d8` 的源码快照，`tree-v2` 只加入仲裁树，`recovery4` 再加入恢复加宽；`store-handoff` 与 `store-yield` 是在其基础上的被拒候选。`final` 是清理后的正式 RTL 快照，与 `recovery4` 的测得周期一致。`suite-baseline` / `suite-final` 是各两种 Cache 的完整官方套件。

`ppa-baseline` / `ppa-final` 是默认 Cache 下的同流程 PPA，`ppa-final-large` 使用大 Cache。各目录保存工具日志、命令、冻结文件、哈希、原始 STA 路径与修复检查。早期脚本在首次测量后扩展了 Cache 参数，旧脚本原文及其匹配哈希保存在对应目录的 `ppa.py` / `code-archive.json` 中。

早期缺少层次化统计信号的构建失败、`correctness_pi` 的初始过小周期上限、完整 Yosys `opt` 的超时、MDU 旧同拍复用断言失败均保留在原始目录。以完成且 `passed=true` 的结果为准，不从失败日志抽取通过结论。最终单测日志是 `checks/final-unit-v3.log`，lint 是 `checks/final-lint-v3.log`；MDU 断言失败的非零退出码另由 `checks/mdu-negative-control.json` 验证。

## 重放

在仓库根目录执行。输出目录必须为新的空路径，避免覆盖原始证据。官方测试集、ASAP7/FakeRAM 和工具依赖沿用仓库已有配置；不下载或修改其他仓库。

```sh
timeout -k 5 1800 make unit
timeout -k 5 1200 make lint
timeout -k 5 600 make optimization-unit
timeout -k 5 60 make matrix-unit

timeout -k 5 10800 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 4 \
  --build-root build/optimization-replay/matrix \
  --report build/optimization-replay/matrix.json

timeout -k 5 1800 python3 -B experiments/optimization_20261014/run.py \
  --out build/optimization-replay/final
timeout -k 5 1800 python3 -B experiments/optimization_20261014/qualify.py \
  --build build/optimization-replay/final \
  --out build/optimization-replay/suite-final

timeout -k 5 3600 python3 -B experiments/optimization_20261014/ppa.py \
  --source build/optimization-replay/final/source \
  --out build/optimization-replay/ppa-final
timeout -k 5 3600 python3 -B experiments/optimization_20261014/ppa.py \
  --source build/optimization-replay/final/source \
  --icache 2048,1 --dcache 16384,2 \
  --out build/optimization-replay/ppa-final-large
```

Store 候选可用 `run.py --store-mode handoff` 或 `--store-mode yield` 在新快照中重放；两个补丁互为替代，不叠加。微基准示例：

```sh
timeout -k 5 180 python3 -B experiments/optimization_20261014/probes.py \
  --out build/optimization-replay/probes \
  --builds build/optimization-20261014/baseline-v2 \
           build/optimization-20261014/final \
           build/optimization-20261014/store-handoff \
           build/optimization-20261014/store-yield
```

`report.py` 审核本次固定输出命名；重放时需指向对应记录，不能把不同源码或约束的报告混在一起。完整功能矩阵的 `--all-performance` 是本轮新增选项，默认轻量回归仍只运行 multiply/vvadd。
