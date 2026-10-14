# 三项IPC优化的轻量验证

最终实现位于正式 `rtl/`。`run.py`复用上一轮有超时、单线程、仅三个官方程序的驱动，改用适配多在途LSQ的只读观测器；默认Cache未改。运行时必须为输出选择新目录，不能覆盖旧证据。

```sh
timeout 280 python3 -B experiments/ipc_20261014/run.py \
  --variants baseline --out build/ipc-final-new
timeout 280 python3 -B experiments/ipc_20261014/run.py \
  --variants i2k-d16k-2way --out build/ipc-large-new
timeout 60 make -j1 memory-unit dcache-unit
timeout 60 make -j1 predictor-unit fetch-unit
```

`baseline`在驱动中是“原Cache几何”的标签，不表示旧CPU；运行的是当时工作区的CPU源码。所有程序仍用原始官方内存模型、延迟10、预期返回值和动态指令数。三项子集均值不能用于评分。

保留的分阶段结果：

- `build/cache-20261014-v2/baseline/`：上一轮原核心/原Cache基线。
- `build/ipc-20261014/load-pilot-v2/`：只增加Load流水化。
- `build/ipc-20261014/store-pilot/`：再增加Store提交优化。
- `build/ipc-20261014/combined-pilot/`：最终三项组合，原Cache。
- `build/ipc-20261014/combined-large/`：最终三项组合，2 KiB I/16 KiB两路D。

`stage-loads.patch`、`stage-stores.patch`是分别相对提交`b2796e2`的累积RTL补丁，仅用于在独立副本复现中间阶段。已逐字节重建对应LSQ源码并与各阶段实际记录的SHA256核对；它们不是应继续叠加到最终RTL上的补丁。其他模块保持该基线版本。

`qualify.py`在本机保留的四阶段模拟器上生成/执行两个通用微基准，然后仅构建FE=BE=2、PRF64、ROB32的一份退休差分模型与一份精确异常模型。它要求上述模拟器已经存在，并拒绝覆盖既有`build/ipc-20261014/qualification/results.json`；适合复核本次归档，不能当成从空build目录自动重建全部阶段的入口。

```sh
timeout 450 python3 -B experiments/ipc_20261014/qualify.py
```

该命令的本轮结果已经保存在qualification目录，无需重复运行。每次构建最多180秒、每次测试30秒，单线程，只有一个退休差分种子和五个异常用例。原始日志、命令、镜像与模拟器哈希均保留。

`results-summary.json`汇总各阶段结果、原始JSON和测试日志哈希、最终硬件与验证输入哈希。`full_suite=false`、`synthesis_run=false`保持显式，不生成完整评分或PPA通过标记。

结论及限制见 [优化报告](../../docs/ipc-optimization-20261014.md)。
