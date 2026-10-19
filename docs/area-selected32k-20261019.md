# 保留 0.90 IPC 的面积优化方案

## 选择与测量记录

用户于 2026-10-19 明确选择约 32,000 µm²、IPC 0.90 的方案合入本地 main，优先保留吞吐。原先 31,000 µm² 的面积目标尚未达到，不能把本次选择写成三项原目标全部达标。

原始同源测量为 IPC 几何平均 **0.9007608693**、面积 **32021.553087 µm²**、估计 Fmax **360.436466 MHz**。FE4/BE4、PRF56、ROB32、整数 RS 8 项、LSQ8、恢复宽度7；D-Cache 16 KiB 双路、每路四 bank、两 MSHR，I-Cache 1 KiB 单路；Store directory 关闭，hints 为8。25 项官方程序全部通过。

补丁为零上下文 unified diff，应用时使用 `git apply --unidiff-zero`；已从基线重建并核对25份文件哈希。精确原始 RTL 可由检查点 `6056713ff3ac8e2d3cb018226dbdfafe09553f88` 加上 `experiments/load_store_throughput_20261019/selected32k-original-source.patch` 恢复。逐文件 SHA256 和六项 IPC 保存在同目录的 `selected32k-original-results.json`。原始完整源、投影源、映射网表、STA 与程序日志保留在 `/private/tmp/verilogcpu-throughput-20261019/lean-fe4-dir0-v2-run`。

后续较小面积方案和 PRF 写入共享实验不纳入合并。它们的冻结源、结果和合并前工作副本仍保留在 `/private/tmp/verilogcpu-throughput-20261019`，工作副本归档为 `pre-select32k-uncommitted`。

## 面积改动与接线

PRF 的每个读口将地址解码成互斥的行选择信号，与对应初始化位共同控制该行32位数据，再由平衡 OR 树合并。地址0和超出实际物理寄存器数的叶子固定输出0；未初始化行也输出0。原有同周期写旁路和多写口冲突优先级保持，写入及惰性复位逻辑不变。初始化位0仅保留原索引布局，解码读不使用它，因此在该声明处局部标记未使用位。

关闭顶层 Store directory，保留8项 hints、晚确认、完整请求身份校验与原错误路径。Cache 仍经过 s0/s1/s2/响应寄存器，维持三周期命中契约。Load 直接交接与 Store 准备/连续推进结构见 `load-store-throughput-20261019.md`。

为保持选定测量快照，恢复原有 RTL 结构和声明顺序；仅对条件生成分支和架构零寄存器中未使用的声明加入局部 Verilator 注记。这些注记不参与 Yosys 综合。

## Store 排序检查器

旧 tagged-core 检查器仅接受提交槽0的 Store，无法描述普通 Store 使用真实退休前缀后的提交槽这一协议。失败波形显示请求标签105、提交槽标签104/105/106/107、`commit_fire=0001`、无异常和恢复，属于槽0真实退休时槽1的合法交接。

新检查器根据完整请求 ROB 标签、有效 Store 指令、LSQ 身份存在、无异常以及每个更老槽的真实退休来校验提交边界；MMIO 仍只能使用槽0，并要求无在途请求、正确地址、整字节使能和正确退出值。检查器自身覆盖未退休前缀、退休空洞、异常/无效前缀、错 ROB 代际、缺失身份、非 Store 指令及 MMIO 越位等拒绝情形。

精确 FE4/BE4/PRF56/ROB32/恢复宽度7 的三组顺序和三组乱序退休轨迹已通过；乱序轨迹分别观察45、39、42次真实前缀 Store 交接。最终合并使用修正后的检查器重新执行完整资格验证，并保存最终报告。

## 最终同源测量

`selected32k-original-final-run` 已独立复验，六项 IPC、面积和估计 Fmax 与原始选定结果完全一致：**0.9007608693 / 32021.553087 µm² / 360.436466 MHz**。suite 与 PPA 共同使用快照 SHA256 `62150977082e85f479a009b9b14bc26b7d778ca43d4cf35f2c06d7383acd3e69`；进程正常退出，源和工具哈希未变。

| 程序 | 周期 | IPC |
| --- | ---: | ---: |
| median | 10662 | 0.652879385 |
| multiply | 18068 | 1.202235997 |
| qsort | 162777 | 0.859458032 |
| rsort | 153693 | 1.273441211 |
| towers | 6376 | 0.827791719 |
| vvadd | 6023 | 0.751120704 |

顶层默认配置使用 FE4/BE4/PRF56/ROB32、directory0、hints8。原始冻结源码中 BE 默认值为2，测量投影显式改为4；合并版本将原默认值也统一为4。两者经过标准投影后的23份 RTL/头文件逐字节一致，另用未覆盖参数的原始默认构建重跑25项官方程序，全部通过且周期完全一致。参数矩阵对 FE/BE/PRF/ROB 均显式覆盖，所以默认值调整不改变矩阵中的各配置。

## 最终资格验证

全部进程正常退出，最终 JSON 均通过完整性、退出状态和源码哈希核对；汇总为 `experiments/load_store_throughput_20261019/selected32k-qualified-results.json`。

- `make unit lint hum-unit` 全部通过；其中 LSQ 交接34项（32正例、2旧版负对照）、PRF复位15项、MSHR123项、Store确认64项、directory71项、整数RS复用9项、response-owner6项、deep17项、HUM28项。
- 完整参数矩阵81组、381项检查：324项 Verilog-2005/启动/Verilator/Yosys 静态检查，9组完整功能配置共243次程序运行，27条退休轨迹；零失败。
- 选定 FE4/BE4/PRF56/ROB32/恢复宽度7 的三组顺序和三组乱序退休轨迹通过，普通Store前缀交接有实际覆盖；MMIO队首约束保持。
- Issue arbiter 的9组 ABC CEC 等价、PRF56 的 BE1/2/4 三组顺序等价、Memory RS 的26组周期对照全部通过；Memory RS 每组6000次检查。
- 官方25项程序和同一投影快照PPA通过；未覆盖参数的 BE4 默认构建另通过25项程序。顶层默认值调整的输入等价证据一并归档。

较小面积和PRF共享写入候选、过时检查器的失败日志，以及中断的验证尝试保留在实验根目录，未作为本次通过证据。约32k方案按用户选择合入，本次仍不宣称达到原31k面积上限。

## 复现

保持官方 Yosys 0.63 / ABC / ASAP7 RVT TT / FakeRAM / OpenSTA 流程，opt、2 ns 目标、INVx1 驱动、5 fF 负载和理想时钟，无布局寄生。Fmax 是该流程的估计值。

冻结命令：`python3 -B experiments/load_store_throughput_20261019/measure.py --phase prepare --source . --out <fresh-absolute-directory> --fe 4 --be 4 --phys 56 --rob 32 --directory 0 --hints 8`，随后对同目录运行 `--phase suite`、`--phase ppa`。其他门禁为 `make unit lint hum-unit`、`tools/run_parameter_matrix.py --all-performance`、`qualify_retirement.py`、`prove_logic.py --kind issue`、`prove_logic.py --kind prf` 和 `compare_memory_rs.py`。未覆盖参数的默认构建可用 `python3 -B ../RISC-V-CPU-2026/scripts/build.py --filelist verilog/filelist.f --out <fresh-default-build> --jobs 2` 复现。所有实验和门禁均设置 timeout。
