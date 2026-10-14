# 六程序瓶颈调查

结论、统计口径与七条优化方向见 [调查报告](../../docs/bottlenecks-20261014.md)。本目录只增加观测和实验工具，正式 RTL 不变。`results-summary.json` 保存 72 次性能运行与 5 个微基准的计数、配置、哈希和原始记录路径。

## 复现

从仓库根目录运行；`run.py` 要求输出目录不存在，避免覆盖原始证据。以下目录为本次已完成结果，重跑时使用新的目录名：

```sh
python3 experiments/bottlenecks_20261014/run.py --out build/bottlenecks-20261014/profile-v2 --variants default big
python3 experiments/bottlenecks_20261014/run.py --out build/bottlenecks-20261014/sensitivity --variants i1-d4-2way i1-d8 i1-d16 window recovery8 wide4 lsq16 predictor
python3 experiments/bottlenecks_20261014/run.py --out build/bottlenecks-20261014/width-isolation --variants fe4-be2 fe2-be4
python3 experiments/bottlenecks_20261014/probes.py --sim build/bottlenecks-20261014/profile-v2/big/sim --out build/bottlenecks-20261014/probes
python3 experiments/bottlenecks_20261014/report.py
```

`report.py` 审计本次固定目录，不运行仿真；使用其他目录时同步修改 `RAW` 和分组路径。它会拒绝源码、模拟器或日志漂移、未完成运行、计数不一致以及旧基线无法复现。正式源码哈希与上一轮 PPA 所用源码核对；本轮不生成新 PPA。

依赖现有 Verilator、GNU timeout、官方框架/FakeRAM、测试集，以及已有 `experiments/cache_20261014/run.py` 和 `tools/generate_core_vectors.py`。构建 360 秒超时，程序 30 秒超时，性能程序上限 300 万周期。使用 `--assert --trace --public-flat-rw`；`--trace` 为官方 harness 的链接需要，不要求生成波形文件。

## 计数说明

- `partition_*`：互斥退休状态分类，分母为总周期。`partition_retire` 表示至少一条指令退休；其他分类仅在没有退休时记录。
- `store_stage_*` 和 `load_stage_*`：分别细分队首 Store 等响应和队首 Load 未完成，已核对各自合计。
- `active_cycles`：排除 `pipeline_hold` 后的周期；资源占满、发射/完成/dispatch 宽度均按此采样。资源状态可能重叠，不能相加当总停顿。
- `retired_*`：实际退休指令分类；最终结束 MMIO Store 被 harness 观察后终止，未计入退休数，故合计为官方动态指令数减一。
- `control_*` / `mismatch_*`：被接收的执行控制流完成，包含推测路径；不等于退休分支准确率。前端返回修正单独记录。
- `dependent_load_present`：至少有一个地址已知、未开始且被 Store 依赖检查阻挡的 Load；不是队首等待，更不是全部 Load 的占比。
- `load_candidate_with_inflight`：候选 Load 与在途请求同时存在，不能当作请求受阻；真正请求反压、在途满分别记录。
- `dcache_nonrun`：Cache 控制器非 RUN；可能与各类等待和退休重叠，不等于全部周期都损失在外存。

`profile.h` 在官方 memory step 前采样组合状态，统计本拍握手。归档脚本可能早于当前 `run.py` 增加宽度选项的版本，原始结果中的 runner 哈希指向各自归档副本。外部输入哈希在报告时补记，并明确标注这个边界。

五个微基准仅用通用循环比较依赖和吞吐；结果与退休数由独立架构解释器核对，没有修改程序去适配性能测试答案，也不包含测试点 PC 特判。参数候选通过六个性能程序不等于通过全部正确性与 PPA 验收。
