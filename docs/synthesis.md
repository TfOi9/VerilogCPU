# 第 26 项 ASAP7 综合与时序评估

## 结构与接线

综合顶层为 `student_top`，包含取指、乱序核心、L1 I/D Cache 和共享
AXI4-Lite 桥。外部 256 MiB RAM 与 testbench 不在 filelist 中，不计入面积。
Cache 数据和标签阵列保持官方 `sram_fakeram` 接口；官方流程在 elaboration
后生成带 Liberty 面积和时序模型的 SRAM 宏，valid、dirty、替换状态仍计入逻辑。

`tools/run_synthesis.py` 读取现有 filelist，在构建目录中复制 RTL 与 header，
将 `student_top.v` 中 FE、BE、物理寄存器、ROB 的四个常量默认值改为指定配置。
Yosys `opt_hier` 会把合法的 `.port()` 空连接判为 0 位宽度错误，
因此副本省略显式空连接，端口仍然悬空，接线语义相同。该投影不会改写仓库源码；
空连接转换的单元测试分别编译和仿真原版、副本，并比较预期输出。
寄存器地址宽度、ROB 索引与 generation 位继续由原 RTL 推导。每个副本先经过
Icarus `-g2005` 和启动参数检查，再调用官方 Makefile 的 `synth` 目标。
官方综合前端使用 `read_verilog -sv` 以兼容其 FakeRAM；本项目 RTL 和生成顶层
均通过独立的 Verilog 2005 检查，不依赖 SystemVerilog 语法。

`diagnose` 保留层次，便于定位组件面积；`opt` 展平后优化，用于最终面积与频率评估。
两种模式分别保存 elaboration、Yosys 脚本、完整日志、映射网表、FakeRAM manifest、
面积 JSON、SDC、OpenSTA 完整路径和官方报告，不将两者面积相加。

## 依赖与约束

`make synth-setup` 下载并核对 `third_party/synthesis-lock.json` 中固定的
Yosys、ABC、cxxopts、ASAP7、OpenSTA 与 CUDD 归档和 Liberty 校验和，
并在 `.deps/` 下构建原生 Yosys/ABC/OpenSTA。
版本取自官方 Dockerfile：

- ASAP7 7.5-track r28 RVT TT NLDM：`f970bd3c3292b79ae4d022a3ec80533534614066`。
- OpenSTA：`f89887b59600cd3a2a10c3de31bda4235d904cdf`。
- CUDD：`f54f533303640afd5dbe47a05ebeabb3066f2a25`。
- Yosys 0.63：`70a11c6bf0e8dd669f56c7da3587f78b405138e2`。
- ABC：`8e401543d3ecf65e3a3631c7a271793a4d356cb0`，来自上述 Yosys 的 submodule。
- cxxopts：`4bf61f08697b110d9e3991864650a405b3dd515d`，来自上述 Yosys 的 submodule。

macOS 构建依赖为 `cmake`、`swig`、`eigen`、`autoconf`、`automake`、
`libtool`、`bison`、`flex`、`tcl-tk@8`、`p7zip`、`pkg-config`、`libffi`、Clang；
Linux 可使用对应原生包。安装脚本使用 Python 3.12 或更新版本。
OpenSTA 归档构建仅将 CMake 的版本字符串设置为归档对应的 upstream commit，
避免错误继承外层 CPU 仓库的 Git revision；分析器源代码不改动。
Yosys/ABC 默认使用 `.deps/yosys/bin/` 中的固定版本，可通过 `YOSYS`、`ABC` 显式替换。
Yosys 关闭 Python 流程不使用的 Tcl 与 readline，综合器逻辑不改动。
系统 Yosys 0.68 的 `diagnose` 层次优化曾出现上述空端口检查错误，
0.63 的 `opt_hier` 源码也包含该检查，因此需要等价的空连接投影。
初次失败日志保存在 `build/synth-version-mismatch/`，最小复现在
`build/synth-port-repro/`；最终矩阵使用官方固定版本和投影后的副本重新执行。

首轮综合还发现 LSQ 字节 forwarding 的通用移位器触发大量 SAT 共享分析。
RTL 将这一处字节提取改成按 2 位偏移选择四个 8 位切片；实际代码与原表达式的
等价性由 Yosys SAT 证明。原日志保存在 `build/synth-before-byte-mux/`。
该改动同步重跑全部组件单元测试和第 25 项静态/功能矩阵，不改变微架构或周期行为。

时序约束完全使用官方 `timing.tcl`：默认周期 2 ns；输入和输出预算各 0.2 ns；
输入与时钟 transition 各 0.05 ns；clock uncertainty 为 0.05 ns；输出负载为 5 fF；
reset 固定为 0。频率搜索同时检查 setup、最小周期和时钟脉宽，分辨率为 0.001 ns。
这是理想时钟、无布线寄生的逻辑综合估计，SRAM 为官方 FakeRAM 估算模型。
负 setup slack 表示未满足指定目标周期，不代表综合流程失败。

## 检查与报告

官方流程用 `hierarchy -check`、`check -assert`、latch/init 禁止检查和映射后
网表重新读入检查，拒绝 latch、未驱动网、未解析模块和未映射单元。
OpenSTA 的约束完整性、组合环及 Tcl 错误必须检查成功后才生成结果。
本地汇总进一步检查组合/时序面积与逻辑面积一致、SRAM 实例面积与 SRAM 总量一致、
逻辑与 SRAM 恰好计入总面积一次，并要求有效的频率、slack 和关键路径。
JSON 同时记录原始输入、生成副本和实际工具二进制的 SHA-256。

每个模式默认墙钟上限 1800 秒；超时杀掉整个工具进程组，包括 ABC、OpenSTA 等子进程。
矩阵默认最多并发两个配置，同一配置的两种模式顺序运行。
JSON 启动即标记 `completed=false`、`passed=false`，逐项保存失败与日志。
完整结束且 RTL、header、filelist、运行器、Makefile、官方脚本、输入 Liberty 均未变化后，
才标记完成与通过。部分配置或单模式报告带有明确范围，不能充当完整矩阵验收。

`reports/synthesis-matrix.json` 保存 9 个代表配置的 18 项结果、原始官方报告、
工具命令、墙钟上限、耗时、源码及库 SHA-256。相邻 `.md` 文件给出面积与频率表。
每项原始产物位于 `build/synth/FExBE-pPHYS-rROB/MODE/`。

```sh
# macOS native build prerequisites
brew install cmake swig eigen autoconf automake libtool bison flex tcl-tk@8 p7zip pkg-config libffi
make synth-setup
make doctor
make synth-unit
make synth MODE=diagnose
make synth MODE=opt
make synth-matrix
```

单独评估配置：

```sh
make synth FE_WIDTH=4 BE_WIDTH=2 PHYS_REGS=48 ROB_ENTRIES=64 MODE=opt
make synth MODE=opt CLOCK_PERIOD_NS=3.333 SYNTH_TIMEOUT=1800
```

也可通过 `STA` 和 `ASAP7_LIB` 指定已有原生安装；Linux `APPIMAGE` 非空时
由官方工具包选择内部的 Yosys/ABC/OpenSTA 和库。

## 本次验证

LSQ 字节选择修改后，2026-10-13 重跑 `make unit`、`make synth-unit` 和
`make matrix TESTCASES=../RISC-V-CPU-2026-Testcases`，全部通过：
81 个配置的 324 项静态检查、9 个代表配置的 207 个功能程序和 27 组退休差分均通过。
矩阵共 381 个步骤，报告的 `completed`、`passed`、`sources_unchanged` 均为 true。
各配置的 `pi` 周期数与第 25 项原表一致。综合测试共 6 项，包括实际字节选择的 SAT 等价证明。
日志分别为 `build/step26-unit.log`、`build/step26-matrix.log`，等价证明保存在
`build/synthesis-unit/forwarding_equivalence.log`。

2026-10-13 完成 `make synth-matrix`：9 个代表配置的 `diagnose` 与 `opt` 共 18 项全部通过。
每项均通过映射前后结构检查、latch/init 禁止检查、未驱动网与未解析模块检查，以及 OpenSTA 约束完整性和组合环检查。
汇总报告的 `completed`、`passed`、`sources_unchanged` 均为 true；结束后再次核对全部输入文件、库与工具二进制的 SHA-256，均一致。
所有配置均保留 34 个 FakeRAM 宏，SRAM 面积为 1994.040 µm²；数据与标签阵列计入该项，外部 RAM 不计入总面积。

下面是 `opt` 网表结果，面积单位为 µm²，频率单位为 MHz，slack 对应 2 ns 目标。

| FE | BE | PHYS | ROB | 组合 | 时序 | SRAM | 总面积 | Fmax | Setup slack (ns) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 48 | 16 | 7113.101 | 4216.536 | 1994.040 | 13323.677 | 74.08 | -11.4982 |
| 1 | 2 | 64 | 32 | 9151.764 | 4917.251 | 1994.040 | 16063.055 | 51.23 | -17.5204 |
| 1 | 4 | 96 | 64 | 15347.899 | 6720.505 | 1994.040 | 24062.445 | 25.38 | -37.4028 |
| 2 | 1 | 64 | 64 | 8797.659 | 5832.000 | 1994.040 | 16623.700 | 46.26 | -19.6162 |
| 2 | 2 | 96 | 16 | 11098.267 | 5154.322 | 1994.040 | 18246.629 | 30.81 | -30.4607 |
| 2 | 4 | 48 | 32 | 13521.215 | 4972.655 | 1994.040 | 20487.910 | 35.75 | -25.9708 |
| 4 | 1 | 96 | 32 | 8738.027 | 5606.885 | 1994.040 | 16338.952 | 34.73 | -26.7927 |
| 4 | 2 | 48 | 64 | 12163.817 | 5843.372 | 1994.040 | 20001.229 | 31.39 | -29.8541 |
| 4 | 4 | 64 | 16 | 15121.545 | 4515.426 | 1994.040 | 21631.011 | 32.93 | -28.3658 |

这些结果确认综合流程完成；全部 `opt` 估算频率为 25.38–74.08 MHz，均未达到 300 MHz，2 ns 目标下全部 setup slack 为负。
`diagnose` 保留层次，结果与 `opt` 不保证单调；例如 `4×2` 的估算频率从 41.85 MHz 变为 31.39 MHz，不能将两种网表的最优分项拼成一组结果。
多数层次报告的关键路径从取指或完成广播寄存器到保留站；完整路径、网表和源码位置均保存在原始报告中，可用于后续定位。
本次未进行时序收敛或物理布局布线，未证明课程面积/IPC/频率联合门槛达标；全部性能程序、IPC 和面积/频率比较属于第 27 项。

完整两模式表格为 `reports/synthesis-matrix.md`，机器可读报告为 `reports/synthesis-matrix.json`，运行日志为 `build/step26-synthesis.log`。
