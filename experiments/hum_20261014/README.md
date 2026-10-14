# Cache 访存并行化实验

本轮基线为本地提交 `2ec87af`，完整源码在编辑前冻结于 `build/hum-20261014/baseline/source`，六项周期和修复后的同流程 PPA 均重新复现。不得以不同 Cache、宽度或修复阶段的数值组合达标。

`run.py` 冻结每个候选并运行六个官方性能程序，固定 FE=BE=2、PRF64、ROB32、恢复宽度4、I 1 KiB / D 16 KiB两路、Store 提示16项、外存10周期。`legacy`、`bridge`、`overlap`、`hum` 分别对照兼容通路、仅桥接并行、写回/refill 重叠和完整组合。`dcache_nonrun` 在新结构中表示 miss 状态活跃，不能继续解释为 Cache 完全不能处理命中。

```sh
timeout -k 5 1800 make unit
timeout -k 5 1800 make lint
timeout -k 5 300 make deep-unit
timeout -k 5 1200 make hum-unit HUM_OUT=build/hum-replay/unit

timeout -k 5 1800 python3 -B experiments/hum_20261014/run.py \
  --out build/hum-replay/performance --variants legacy bridge overlap hum

timeout -k 5 10800 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 4 \
  --build-root build/hum-replay/matrix --report build/hum-replay/matrix.json

timeout -k 5 3600 python3 -B experiments/deep_20261014/ppa.py \
  --source build/hum-replay/performance/hum/source \
  --out build/hum-replay/ppa --store-hints 16 --icache 1024,1 --dcache 16384,2
```

PPA 包括映射、固定状态/CEC、电气修复及20 ps hold 约束，引用最终修复报告。各阶段独立保留源码、模拟器、原始日志、输入和哈希，禁止将中止或失败的运行计入验收。SORA 未修改，所有 Git 提交仅本地保存。

最终选择 v6 的 RTL，冻结于 `build/hum-20261014/selected-final/source`。该目录的 RTL 与 `selected-v6/source` 逐字节一致，因此采用已完成的 `ppa-v6/results.json`，不是将不同源码或配置的性能/PPA 拼接。v7 的最后返回缓冲数据路径调整降低估计频率，已撤回。最终源码重跑全套验收，证据目录为：

- `baseline-perf`、`ppa-baseline`：编辑前源码的六程序和 PPA 重测。
- `screen-final`：四组消融，每组六个官方性能程序。
- `suite-final`、`official-final`：选定大 Cache 配置的25个官方程序及构建命令。
- `matrix-final.json`、`matrix-final/`：81组参数静态检查、九组代表配置的程序及退休轨迹回归。
- `hum-unit-selected`、`gates-final`、`negative-final`：新增28项、原有 unit/lint/deep-unit、三项契约负向检查。
- `posted-wrap-proof`：旧基线的标签回绕失败及最终修复后的通过，含命令和源码哈希。
- `probes-baseline-confirmed`、`probes-final`：五组依赖链微基准。
- `ppa-v1`、`ppa-v3` 至 `ppa-v7`：各中间候选的最终 PPA；失败和中止目录另存，不能算作通过。

```sh
timeout -k 5 300 python3 -B experiments/hum_20261014/report.py --ppa-version v6
```

审核脚本重新核对冻结输入和日志哈希、基线周期复现、最终 RTL 与 PPA 原快照一致、官方性能与带计数器运行一致，以及所有验收数量与通过状态，然后生成 `results-summary.json` 和 `docs/cache-parallel-optimization-20261014.md`。只报告最终修复后的面积/频率；IPC×估计频率是吞吐代理指标，不是实芯片吞吐。
