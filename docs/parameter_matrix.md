# 第 25 项参数回归矩阵

## 参数与接线

`student_top` 和 `rv32_cpu_core` 根据容量自动计算物理寄存器地址宽度与 ROB 索引宽度，ROB tag 在索引之上保留两位 generation。顶层将这些位宽传给核心，核心继续传给 rename、PRF、ROB、各保留站、发射仲裁、LSQ 和完成网络，因此只需修改容量参数。显式指定错误的位宽仍由已有模块的启动检查拒绝。

物理寄存器数允许 48、64、96 等非二次幂容量，地址宽度分别为 6、6、7；ROB 容量为 16、32、64 时，索引宽度分别为 4、5、6，tag 宽度分别为 6、7、8。其余队列与 I/D Cache 使用默认参数。退休差分测试同样根据 ROB 容量计算 tag 位切片。

## 检查结构

`tools/run_parameter_matrix.py` 对 `FE_WIDTH={1,2,4} × BE_WIDTH={1,2,4} × PHYS_REGS={48,64,96} × ROB_ENTRIES={16,32,64}` 的全部 81 个配置分别执行：

- Icarus `-g2005` 编译完整 `student_top`，并执行启动参数检查；`SYNTHESIS` 使官方 FakeRAM 仅保留库接口，真实存储行为在功能阶段验证。退出码为零但打印 `ERROR` 也视为失败。
- Verilator lint；项目 `.v` 使用 Verilog 2005，仅官方 FakeRAM `.sv` 使用 SystemVerilog。忽略已有的文件名、空统计端口和未使用信号告警，宽度、latch 等告警仍导致失败。
- Yosys `read_verilog`、层次检查、过程转换和优化，并禁止 latch；`check -assert` 要求无结构错误。FakeRAM 使用官方库接口作为 blackbox，此处不进行面积或频率评估。

独立配置默认以两个 worker 执行静态检查；同一配置的依赖步骤顺序执行，报告写入加锁。每个工具都有墙钟上限。不同配置使用独立目录，避免覆盖模拟器或日志。

以下 9 个代表配置覆盖全部 FE/BE 组合，以及全部物理寄存器/ROB 容量组合：

| FE | BE | PHYS_REGS | ROB_ENTRIES | 功能程序 | pi 周期 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 48 | 16 | 23/23 | 21373512 |
| 1 | 2 | 64 | 32 | 23/23 | 20176294 |
| 1 | 4 | 96 | 64 | 23/23 | 20170708 |
| 2 | 1 | 64 | 64 | 23/23 | 20184652 |
| 2 | 2 | 96 | 16 | 23/23 | 21364927 |
| 2 | 4 | 48 | 32 | 23/23 | 20175085 |
| 4 | 1 | 96 | 32 | 23/23 | 20196559 |
| 4 | 2 | 48 | 64 | 23/23 | 20195365 |
| 4 | 4 | 64 | 16 | 23/23 | 21382417 |

每个代表配置运行 seed `0x2401`、`0x2402`、`0x2403` 的逐条退休差分，以及 19 个官方 correctness、`perf_multiply`、`perf_vvadd` 和两个本地 smoke。差分比对 PC、原指令、目的寄存器及结果，继续检查 Store 必须位于 ROB 头部、满宽发射/写回/退休、分支恢复和旧响应处理。官方模拟器使用相同 FakeRAM 与 AXI harness，启用 100000 周期无退休 watchdog；每例上限为 30000000 周期、1800 秒墙钟时间，外存延迟 10 周期。

## 报告与复现

`reports/matrix.json` 记录配置、seed、源码与测试脚本 SHA-256、测试集 Git 版本、工具命令、timeout、状态和日志路径，并汇总所有程序结果。启动即写入 `completed=false`；所有步骤结束且源码未变化后才写入最终状态。局部运行的报告带有 `phase` 和 `focused_config`，不能当作完整矩阵通过。

程序失败时保存实际输入、输出日志和带波形路径的复现命令；退休差分失败时日志给出配置、seed、首个不同的 PC 或寄存器结果，报告提供同一刺激的 VCD 复现命令。生成文件均由现有 `.gitignore` 排除。

```sh
make matrix TESTCASES=../RISC-V-CPU-2026-Testcases
make matrix-lint TESTCASES=../RISC-V-CPU-2026-Testcases
make matrix-functional TESTCASES=../RISC-V-CPU-2026-Testcases
make test-configured FE_WIDTH=4 BE_WIDTH=2 PHYS_REGS=48 ROB_ENTRIES=64 \
  TESTCASES=../RISC-V-CPU-2026-Testcases
```

聚焦单个配置：

```sh
/opt/homebrew/bin/python3 tools/run_parameter_matrix.py \
  --config 4,4,96,64 --phase functional \
  --report reports/matrix-focused.json
```

配置构建入口在非默认容量下添加 `-pPHYS-rROB` 后缀；默认 64/32 容量继续使用原有目录。矩阵专用产物位于 `build/matrix/FExBE-pPHYS-rROB/`。

## 本次验证

2026-10-13 完成 `make matrix TESTCASES=../RISC-V-CPU-2026-Testcases`：

- 81/81 个配置通过 Icarus 编译、启动检查、Verilator lint 和 Yosys 检查，共 324 项静态检查。
- 9/9 个代表配置完成全部 23 个功能程序，共 207/207 项通过。
- 27/27 组退休差分通过，共比对 24849 条退休记录；三个 seed 每组分别退休 917、923、921 条指令。
- `make unit` 全部通过；`make matrix-unit` 的 3 项脚本测试通过，覆盖代表配置完整性、零退出码错误输出、进程失败、超时、缺失工具和非法容量。

测试集版本为 `29f980727f7d99a1842a58f34091c7579ba3fe85`。完整 JSON 的 `completed`、`passed`、`sources_unchanged` 均为 true；包括刺激生成与模拟器构建在内的 381 个步骤全部通过。组件单元测试日志为 `build/step25-unit.log`，矩阵运行日志为 `build/step25-matrix.log`。表中的周期仅为功能回归原始记录，正式 IPC、面积与频率评估留在后续阶段。
