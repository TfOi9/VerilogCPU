# Store 与结果通路优化实验

正式元件设计见 [设计文档](../../docs/posted-stores-and-result-bypass.md)。不修改 SORA，不推送。

`run.py` 沿用调查工具的观测 harness，冻结 RTL 后运行全部六个性能程序；`--source` 可指定已冻结基线。每次构建 timeout 360 秒、2 个作业，每个性能程序 timeout 30 秒、上限 300 万周期。`stores-only` 与 `results-only` 为独立消融，`combined` 使用 I 1 KiB / D 16 KiB 两路、FE=BE=2、PRF64、ROB32、恢复宽度4、外存10周期。`default` 使用默认 Cache。

`qualify_official.py` 在官方无逐周期 profile 的模拟器上检查完整 25 程序，记录输入/源码/模拟器/日志哈希并检查运行前后不变；普通程序 timeout 120 秒，`correctness_pi` 600 秒，上限 3000 万周期。`qualify.py` 保留带退休计数的 profile 复核，不能把早期 timeout 记录当作通过。

```sh
timeout -k 5 1800 make unit
timeout -k 5 1200 make lint
timeout -k 5 300 make deep-unit
timeout -k 5 900 python3 -B experiments/deep_20261014/posted_core.py
timeout -k 5 180 python3 -B experiments/deep_20261014/negative_controls.py
timeout -k 5 10800 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 4 \
  --build-root build/deep-replay/matrix --report build/deep-replay/matrix.json

timeout -k 5 1800 python3 -B experiments/deep_20261014/run.py \
  --out build/deep-replay/performance --variants hints16 hints8 combined default stores-only results-only

python3 -B experiments/deep_20261014/project.py \
  --source build/deep-replay/performance/hints16/source \
  --out build/deep-replay/source-hints16 --store-hints 16

timeout -k 5 600 python3 -B tools/build_configured.py \
  --framework ../RISC-V-CPU-2026 \
  --filelist build/deep-replay/source-hints16/verilog/filelist.f \
  --out build/deep-replay/official-large --fe-width 2 --be-width 2 \
  --icache 1024,1 --dcache 16384,2 --jobs 2
timeout -k 5 1200 python3 -B experiments/deep_20261014/qualify_official.py \
  --sim build/deep-replay/official-large/sim \
  --source build/deep-replay/source-hints16 --out build/deep-replay/suite

timeout -k 5 240 python3 -B experiments/bottlenecks_20261014/probes.py \
  --sim build/deep-replay/performance/hints16/sim --out build/deep-replay/probes

timeout -k 5 3600 python3 -B experiments/deep_20261014/ppa.py \
  --source build/deep-replay/performance/hints16/source \
  --out build/deep-replay/ppa --store-hints 16 --icache 1024,1 --dcache 16384,2
```

原始证据位于 `build/deep-20261014/`。`baseline/source` 在首次编辑前冻结；`baseline-run` 重现调查基线。`early` 为写回穿透，`posted` 加入驻留 Store 所有权转移，`load-early` 加入 Load 返回穿透，`combined` 清理 payload 并去除提示重复项，`authorized` 将标签和物理目的查询移到仲裁前。每个阶段单独保留源码、二进制、原始输出与哈希，禁止覆盖旧目录。

PPA 使用已有 ASAP7/FakeRAM 流程，包括映射、电气修复、CEC 和 20 ps hold 门槛；必须查看最终修复后的报告。它是无布线寄生/CTS 的估计，不是物理签核。
