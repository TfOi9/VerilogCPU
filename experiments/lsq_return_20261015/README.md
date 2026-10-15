# 返回控制链优化实验

基线为 `bcd3f31`，本轮只重构 `rv32_memory_reservation_station` 的年龄选择和地址生成，不改变 Dcache、LSQ、完成网络及其快速返回参数。

- `measure.py` 沿用上一轮测量器，冻结 RTL、配置投影、测试程序及工具输入。`sim` 使用官方仿真框架运行全部 25 个程序，六个性能程序按动态指令数计算 IPC 几何平均；`ppa` 调用原始官方 `scripts/synth.py`。
- `compare.py` 从不可变基线提取旧 RS，在相同刺激下逐周期比较全部输出。覆盖 BE=1/2/4、ROB=16/32/64、RS=4/8/16、Load/Store、同周期广播、年龄回绕、回压锁定、flush 和选择性回滚。测试平台为 `tb/rv32_memory_rs_equivalence_tb.v`。
- `boundaries.py` 利用 pre-ABC 重放中保留的寄存器身份，将官方网表的两个 `dcache.r_id` 输出和 256 个 `core.lsq.address` 数据输入关联到 RTL。它读取官方网表、库和 SDC，另存限定起终点的 STA 报告，核验原始 PPA 文件未改变。
- `report.py` 校验当前 RTL 与测量快照相同、所有输入/日志/网表哈希和完整回归，再生成 `results-summary.json`。它同时要求 25 个官方程序周期不变、指定路径缩短、全局估计频率提高，面积仍小于 36,000 um²。

原始证据位于忽略目录 `build/lsq-return-20261015/`：`parallel` 为候选的官方仿真及 PPA；`equivalence-fixed` 为逐周期对照；`gates` 为全量单元、lint、HUM 和返回归属检查；`matrix.json` 为完整参数矩阵；`baseline-boundaries`/`selected-boundaries` 为指定路径；`path-trace-final` 为候选全局关键路径的寄存器身份。

第一次对照测试遗漏向 DUT 和参考模块传入 `ROB_ENTRIES`，ROB=16 时参数检查拒绝启动，原日志保留在 `equivalence/`。修正测试平台后运行全部配置，没有为此更改 RTL。一次误用的 Make 目标名也未启动仿真；实际组件测试使用 `make memory-unit`。

`path-trace` 的第一次诊断与尚未结束的官方 STA 报告生成重叠，文件完整性检查拒绝该诊断。保留日志及已完成的 pre-ABC 重放，在官方测量结束后重跑为 `path-trace-final`；限定路径的 STA 独立读取稳定的官方网表/SDC，并核验官方文件未改变。

复测时使用新的输出目录；以下命令均从仓库根目录运行：

```sh
python3 -B experiments/lsq_return_20261015/measure.py --phase prepare --out build/lsq-return-recheck/parallel --directory 128 --late-confirm 1
python3 -B experiments/lsq_return_20261015/measure.py --phase sim --out build/lsq-return-recheck/parallel
python3 -B experiments/lsq_return_20261015/measure.py --phase ppa --out build/lsq-return-recheck/parallel
timeout -k 5 1800 python3 -B experiments/lsq_return_20261015/compare.py --out build/lsq-return-recheck/equivalence-fixed
python3 -B experiments/store_directory_20261015/validate.py --out build/lsq-return-recheck/gates
timeout -k 5 3600 python3 -B tools/run_parameter_matrix.py --build-root build/lsq-return-recheck/matrix --report build/lsq-return-recheck/matrix.json --all-performance --testcases ../RISC-V-CPU-2026-Testcases --jobs 2 --lint-jobs 2
python3 -B experiments/store_confirm_20261015/trace.py --ppa build/lsq-return-recheck/parallel/ppa/opt --out build/lsq-return-recheck/path-trace-final
python3 -B experiments/lsq_return_20261015/boundaries.py --ppa build/lsq-return-recheck/parallel/ppa/opt --preabc build/lsq-return-recheck/path-trace-final/preabc.json --out build/lsq-return-recheck/selected-boundaries
python3 -B experiments/lsq_return_20261015/boundaries.py --ppa build/store-confirm-20261015/final128/ppa/opt --preabc build/store-confirm-20261015/path-trace/preabc.json --out build/lsq-return-recheck/baseline-boundaries
python3 -B experiments/lsq_return_20261015/report.py --root build/lsq-return-recheck
```

所有构建/仿真/综合/STA 子进程均有 timeout。基线测量沿用已冻结且与 `bcd3f31` 逐文件核对的 `build/store-confirm-20261015/final128`；本轮失败的诊断/测试平台日志在原始目录中保留，复测不要求重现这些操作失误。结果只属于官方框架的综合和理想时钟 STA 估计，不是布局布线签核。
