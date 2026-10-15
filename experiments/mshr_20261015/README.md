# 双 MSHR 与合并请求实验

基线为本地提交 `2a34e20`。选中实现保存于 `build/mshr-20261015/prototype5`；标签名称保留试验历史，不表示未完成验证。功能结构见 [dcache-mshr.md](../../docs/dcache-mshr.md)，验收与 IPC/PPA 结果见 [优化报告](../../docs/mshr-optimization-20261015.md)。

- `measure.py` 冻结 RTL、配置投影、程序、框架和工具输入，调用未修改的官方仿真与综合框架。选择 FE2/BE2、PRF64、ROB32、Icache 1 KiB/1 way、Dcache 16 KiB/2 ways、目录 128 项，外部主存延迟 10 周期；`--mshrs 1/2` 控制顶层配置。
- `profile.py` 把计数钩子加到官方 harness 的本地副本，保持框架文件不变。`profile.h` 检查请求 ID 生命周期、RAM 请求/返回数量、退休数和 MSHR 占用分区，记录两个 D 读在途、合并、阻塞及 LSQ 请求到返回消费的延迟。Profile 的六项周期必须与官方未插桩仿真一致。
- `tools/test_mshr.py` 已接入 `make unit`，运行 99 组配置：88 组 cache、8 组带 ID 桥接、3 个必须拒绝的负对照。覆盖 way=1/2/3/4、主存延迟 1/7/31、读写返回两种顺序、掩码、回压、目录别名、确认、复位、写回错误、refill 错误与两者同时错误。
- `report.py` 核对当前 RTL、官方快照、输入及日志哈希，校验完整单元/lint/HUM/返回归属与 81 组矩阵，再生成 `results-summary.json`。验收要求六项 IPC 均不下降、整体 IPC 提高，面积不超过 36,000 um²、官方估计频率至少 300 MHz。

主要原始证据：

| 目录 | 内容 |
| --- | --- |
| `prototype5` | 25 个官方程序、官方 `opt` PPA、源文件及配置哈希 |
| `profiles/before` | 旧基线的六项计数 |
| `profiles/after` | 双 MSHR 的六项计数 |
| `profiles/control-one` | 同一新 RTL 设回单 MSHR；周期及所有计数必须与旧基线一致 |
| `gates` | 完整单元、lint、HUM、返回归属及原始日志 |
| `matrix.json` | 81 组静态配置、九组功能配置与退休轨迹 |
| `path-trace` | 官方关键路径的 pre-ABC 寄存器身份重放 |

首次 RTL 的 qsort 在 `prototype1` 触发不可失败 Store 保护。`diagnostic2`、`debug3`、`debug4` 保留定位过程；根因是在合并返回暂停时禁用了 S1 的 SRAM 读口，恢复后使用了未定义的 tag。修复保持读口后，新的定向测试能拒绝关闭该修复的变异实现。最初单测还修正了声明位置和使双完成覆盖真正发生的刺激时序；第一次 profile 构建遗漏 `--trace` 的链接失败也保留在 `profile-before`/`profile-after`，随后使用 `profiles/` 重跑。这些失败均未用作性能结论。

复测使用新的输出目录，从仓库根目录依次运行；测量器和验证工具的子进程已有 timeout：

```sh
python3 -B experiments/mshr_20261015/measure.py --phase prepare --out build/mshr-recheck/prototype5 --mshrs 2
python3 -B experiments/mshr_20261015/measure.py --phase sim --out build/mshr-recheck/prototype5
python3 -B experiments/mshr_20261015/measure.py --phase ppa --out build/mshr-recheck/prototype5
python3 -B experiments/store_directory_20261015/validate.py --out build/mshr-recheck/gates
timeout -k 5 3600 python3 -B tools/run_parameter_matrix.py --build-root build/mshr-recheck/matrix --report build/mshr-recheck/matrix.json --all-performance --testcases ../RISC-V-CPU-2026-Testcases --jobs 2 --lint-jobs 2
python3 -B experiments/mshr_20261015/profile.py --source build/lsq-return-20261015/parallel/source --mshrs 1 --out build/mshr-recheck/profiles/before
python3 -B experiments/mshr_20261015/profile.py --source build/mshr-recheck/prototype5/source --mshrs 2 --out build/mshr-recheck/profiles/after
python3 -B experiments/mshr_20261015/profile.py --source build/mshr-recheck/prototype5/source --mshrs 1 --out build/mshr-recheck/profiles/control-one
python3 -B experiments/store_confirm_20261015/trace.py --ppa build/mshr-recheck/prototype5/ppa/opt --out build/mshr-recheck/path-trace
python3 -B experiments/mshr_20261015/report.py --root build/mshr-recheck
```

官方基线沿用 `build/lsq-return-20261015/parallel`，汇总时与 `2a34e20` 逐 RTL 文件核对。先等 PPA 完整结束再启动路径重放，避免完整性检查与报告生成重叠。原始证据存于忽略的 `build/` 目录，紧凑哈希汇总随本次提交保存。面积与频率是官方综合/理想时钟 STA 估计，未进行布局布线签核或功耗测量。
