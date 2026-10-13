# 第二轮隔离实验

基线为 `4fa767cf09cdeebd1ced43973d53490acb6008a5`。所有 RTL、单元测试副本和原始结果均生成到 `build/round2-20261013/`，不改正式 `rtl/`、`tb/`、`tools/` 或 SORA。三个版本互不叠加：

- `baseline`：正式版逐字节快照。
- `lsq-turnover`：仅允许在前一笔 cache response 握手时准备下一笔请求，仍然只有一笔在途事务。
- `rs-ready-cut`：仅 INT RS、通用 MDU RS 的分配候选槽改为拍前空槽，去掉 `issue_remove_mask_reg` 对分配逻辑的依赖。

四个性能/综合配置为 `2×2/P64/R32`、`1×1/P48/R16`、`4×1/P96/R32`、`4×4/P64/R16`。内存延迟固定为 10，I/D cache 容量、相联度、总线与正式版相同。

## 复现

在仓库根目录运行：

```sh
python3 -B experiments/round2_20261013/setup.py
python3 -B experiments/round2_20261013/regression.py
python3 -B experiments/round2_20261013/run.py
python3 -B experiments/round2_20261013/synthesize.py
python3 -B experiments/round2_20261013/electrical.py
python3 -B experiments/round2_20261013/paths.py
timeout 30 python3 -B experiments/round2_20261013/test_checks.py > build/round2-20261013/checks-unit.log 2>&1
python3 -B experiments/round2_20261013/report.py
```

`setup.py` 不覆盖已有快照；发现被保护文件、实验 RTL 或 SORA 状态变化会失败。修改实验定义后须使用新的输出目录，而不能混用本轮结果。仿真单项 600 秒、单元套件 900 秒、矩阵套件 3600 秒、综合单项 2400 秒、电气审计单项 180 秒超时。综合并发为 2。矩阵编译/静态检查默认并发为 4/6，可用 `--jobs`、`--lint-jobs` 调低。本轮 baseline/LSQ 使用 2/2，RS 最终完整矩阵使用 4/6；它只改变宿主机调度，不改变 RTL 参数、种子和验证规则。

`run.py` 的性能计数只存在于 C++ harness，不进入 RTL 或综合。使用 `--public-flat-rw` 保留观测信号，基线周期必须与正式报告一致。缓存命中要求模拟器、输入映像哈希、预期结果及指令数一致；旧模拟器按哈希保存。每组 19 个正确性程序、6 个官方性能程序和 6 个通用微基准。微基准不参加官方 IPC 平均。

## 计数口径

- 官方 IPC 使用程序 `metrics.json` 的动态指令数，六项作等权几何平均。结束 MMIO Store 的总线写响应使官方 harness 结束，早于其 ROB 退休；实测退休数应为官方动态指令数减一。
- 每个非 reset 周期归入唯一的退休/恢复/ROB 空/队头未完成/Store 响应等待类别。占用量、发射、派发、退休宽度直方图均须覆盖所有周期。
- 派发阻塞同时记录**前缀筛选的容量阻塞**和筛选后的握手阻塞。资源重叠计数不能求和；互斥主因按 rename、ROB、INT、MUL、DIV、LOAD、STORE、LSQ 顺序归因，用于守恒而非独立损失估算。
- `rs_reuse_opportunity_*` 是已经筛选出的指令对当拍腾槽的需求；`rs_unused_turnover_*` 是前缀筛选拒绝的首条指令在考虑当拍释放后本可放入的情况。二者不同，后者不意味着整机实际使用过当拍腾槽。
- LSQ 记录请求间隔、响应至下次请求间隔、请求/响应/完成背压、可消泡机会、丢弃/错误响应、Load/Store 延迟；对请求响应及 AXI outstanding 做配对守恒检查。
- Store 记录队头等待的操作数、完成广播、请求调度、请求握手，以及在途时 D-cache 的 RUN/非 RUN 状态；另记录 ready/head/request/array commit/response/retire 间隔。未退休和撤销条目单独计数。
- `cache_run`、`cache_miss_or_mmio` 两个阶段字段实际上只按 D-cache 的 RUN/非 RUN 模式分类，不能直接等同于命中和 MMIO 耗时。MMIO 旁路在 D-cache 空闲时会归入前者，独立 MMIO 计数是 `cache_mmio_requests`；本轮不单独分解 MMIO 各阶段时间。
- `array_commit` 只观测 D-cache 的命中 Store 写入；Store miss 合并进 refill 的写入不在这个直方图中，也不代表外部内存持久化。Store request→response 和 head→retire 统计覆盖完成的 miss Store。结束 MMIO Store 尚未退休，独立记为未完成样本。

## 验证边界

单元测试使用完整正式套件的隔离副本。RS 的满队列 pop/push 定向用例与 Python 随机参考模型同步采用下一拍复用槽位，并继续检查所有数据、标签、发射顺序和占用量。MDU 用例在局部暂停 issue grant 后恢复原值。LSQ 额外覆盖响应交接时的请求背压、完成背压、错误响应、恢复屏蔽和过期响应丢弃，BE=1/2/4。

矩阵套件覆盖 81 个参数组合的 Verilog 2005、参数启动、Verilator、Yosys 无锁存检查，以及 9 个代表配置的退休差分和官方程序。

电气审计直接读取每次综合的 mapped netlist、原 Liberty 与原 SDC，不重新定义约束，不写回正式报告。`max_capacitance` 和 `max_slew` 独立于综合成功状态；只要有违例，`electrical_pass=false`。转换时间违例按引脚数统计，同一慢驱动可对应许多负载引脚。未定义最大 fanout 约束时明确记为 `not_constrained`。

频率是官方流程的布局前、理想时钟、无提取互连寄生估计。SRAM 面积包含官方 FakeRAM 估计。存在电气违例时，IPC×Fmax 及面积效率只能用作该流程内的实验比较。
