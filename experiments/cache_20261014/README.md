# 低负载 Cache 配置对照

只运行 `perf_multiply`、`perf_qsort`、`perf_rsort`，每次构建与执行均串行。固定 FE/BE=2/2、PRF64、ROB32、外存延迟10。默认三个配置：1 KiB I/4 KiB直接映射D、1 KiB I/4 KiB两路D、2 KiB I/16 KiB两路D。正式RTL保持不变。

在仓库根目录执行，需已有官方框架、测试镜像和本地 Verilator：

```sh
timeout 800 python3 -B experiments/cache_20261014/run.py --out build/cache-pilot-new
timeout 60 make -j1 icache-unit dcache-unit
timeout 15 python3 -B tools/test_cache_config.py
```

输出目录须为新目录，避免覆盖旧证据。单次构建超时240秒（含子进程退出），单程序30秒，程序上限3,000,000周期。不开波形、不跑综合。可使用 `--variants d4k-2way` 仅跑一个配置。结果 `full_suite=false`，三程序子集几何平均不是课程评分成绩。

正式构建入口现在也支持显式 Cache 配置，例如以下命令只构建一个候选，不执行测试：

```sh
timeout 240 python3 -B tools/build_configured.py \
  --framework ../RISC-V-CPU-2026 --filelist verilog/filelist.f \
  --out build/cache-configured-2k-16k \
  --fe-width 2 --be-width 2 --phys-regs 64 --rob-entries 32 \
  --icache 2048,1 --dcache 16384,2 --jobs 1 \
  --verilator /opt/homebrew/bin/verilator --cxx c++
```

其他平台应替换 Verilator 路径。只启用同容量两路 D 时传 `--dcache 4096,2`；不传 Cache 参数则使用 `student_top` 默认值。

`profile.h` 在官方 harness 上升沿前只读采样。D 请求类型由仲裁 owner 与 D Cache 的 WRITEBACK_REQUEST 状态区分；调整 RTL 状态编码后需同步观测器。计数守恒、最终返回值或源码完整性检查失败都拒绝生成 PASS。

本次成功记录来自 `build/cache-20261014-v2/results.json`；`results-summary.json` 保留该数据以及轻量单测记录。失败的首次观测器构建独立保存在 `build/cache-20261014/`。

结论及面积预算见 [报告](../../docs/cache-pilot-20261014.md)。
