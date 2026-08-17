# RV32IM 指令译码器

## 功能

`rv32im_decoder` 是单指令、纯组合逻辑模块，负责识别完整 RV32I 与 M 扩展指令，并生成后续重命名、分派和执行单元需要的控制信息。模块不保存 PC、原始指令或流水线 valid，也不包含时钟和复位。多发射前端为每个 lane 实例化一个相同的译码器。

译码器还识别项目约定的 `0x0ff00513` HALT 指令。该编码优先于普通 ADDI 解码，因此不会覆盖 `a0` 中的程序返回值。

## 内部结构

模块首先从指令的固定位置读取 opcode、funct3 和 funct7，然后以 opcode 为主层、funct 字段为次层进行严格匹配。所有输出在组合逻辑入口先设置为 INVALID 的确定值，只有完整匹配合法编码后才写入操作类型和控制字段，因此保留编码不会产生部分有效的控制信号，也不会推断锁存器。

立即数直接按 RISC-V 格式拼接：

- I 型使用 `instruction[31:20]` 并符号扩展；
- S 型拼接 `instruction[31:25]` 与 `instruction[11:7]`；
- B 型重排为 13 位偶数偏移后符号扩展；
- U 型保留高 20 位并在低位补 12 个零；
- J 型重排为 21 位偶数偏移后符号扩展；
- SLLI、SRLI、SRAI 只输出零扩展的 5 位 shamt。

公共操作码、指令类别和访存宽度定义位于 `rv32im_defs.vh`。6 位操作码能够区分 48 条标准指令、HALT 和 INVALID；4 位类别用于将指令路由到整数、访存、分支、乘法、除法或 ROB-only 路径。

## 控制逻辑

`uses_rs1_o` 和 `uses_rs2_o` 表示指令格式是否读取源寄存器。未使用的寄存器编号统一输出零。`writes_rd_o` 只在指令具有目的寄存器且 `rd` 非零时置位；因此写入 `x0` 的标准 HINT 仍保留原操作类型，但不会分配物理寄存器。NOP 保持为 `ADDI x0, x0, 0`，不设置独立操作码。

Load 和 store 同时输出 BYTE、HALF 或 WORD 宽度，LBU 与 LHU 通过 `load_unsigned_o` 指示零扩展。非访存指令输出 NONE。

FENCE 被分类为 SYSTEM，不读取或写入寄存器，并置位 `serialize_o`。基础 ISA 要求忽略 FENCE 的保留字段，因此只要 opcode 和 funct3 匹配就作为保守 FENCE 处理；FENCE.I 不属于 RV32IM，判为非法。ECALL 和 EBREAK 只接受标准精确编码，后续由 ROB 在提交点处理。CSR、AMO、RV64、压缩指令及其他保留编码输出 `legal_o=0`。

## 接线

前端将每个 fetch lane 的 32 位指令连接到 `instruction_i`，并自行携带该 lane 的 PC、原始指令和 valid。重命名逻辑使用寄存器编号、源使用标志和 `writes_rd_o`；dispatch 根据 `class_o` 选择 RS、LSQ 或 ROB-only 路径；执行单元使用 `op_o`、`immediate_o` 和访存属性。非法指令、HALT、FENCE、ECALL 和 EBREAK 的最终提交行为不属于本模块。

## 与 SORA 的差异

SORA 主模拟器的 decoder 只实现常用 RV32I 算术、访存和控制流指令。SORA interpreter 的类型表声明了 M 扩展操作，但实际 decoder 没有对应分支；两套实现也未完整处理 FENCE、ECALL 和 EBREAK，部分非法编码通过 C++ 断言终止。

本模块以 RV32I 和 M 扩展的标准编码为准，完整识别上述指令，并通过 `legal_o` 报告非法编码。组合译码过程不会主动停止仿真。
