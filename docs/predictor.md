# Bimodal 与 BTB 分支预测器

`rv32_branch_predictor` 是组合查询、时钟沿训练的多路分支预测器。`FE_WIDTH` 决定同周期查询数，`BE_WIDTH` 决定同周期提交训练数，二者分别支持 1、2、4。所有跨模块数组均压平成 packed bus，lane 0 位于最低位。预测器没有 backpressure，也不响应分支恢复 flush；错误预测不会清除已经学习的状态，只有同步 reset 会清空表项和统计。

## 预测结构

条件分支共用 64 项 BHT。`PC[7:2]` 直接选择一个 2-bit 饱和计数器，高地址位不构成标签，因此不同 PC 可以有意地 alias 到同一项。计数器复位为 `00`，`00`、`01` 预测不跳，`10`、`11` 预测跳转。预测跳转时下一 PC 为 `pc + immediate`，否则为 `pc + 4`。BEQ、BNE、BLT、BGE、BLTU 和 BGEU 使用完全相同的表项和规则。

JAL 不访问预测表，始终预测跳转并直接计算 `pc + immediate`。JALR 使用 16 项直接映射 BTB，`PC[5:2]` 选择表项，每项保存 valid、完整 32-bit PC 标签和目标。标签命中时预测跳转到保存目标；未命中时预测不跳并使用 `pc + 4`。完整 PC 标签避免同索引的不同 JALR 产生假命中。

无效查询和非控制流操作输出全零。各查询 lane 相互独立，预测结果不负责决定 fetch bundle 的截断位置；后续取指流水线应选择程序顺序中的第一个 `prediction_taken_o`。

## 提交训练与冲突

训练发生在控制流指令提交时。未来 CPU 集成中，`update_valid_i` 应连接 `commit_fire_o && commit_control_valid_o`，其余更新字段直接使用 ROB 保存的操作码、PC、预测 next PC、实际 next PC 和实际 taken。这样被回滚的错误路径不会修改预测状态。

训练 valid 允许稀疏分布，但 lane 顺序必须为 oldest 到 youngest。同周期多个条件分支命中相同 BHT 索引时，从低 lane 到高 lane 逐项更新临时计数器，因此每次训练都生效并保持上下界饱和。同周期多个 JALR 命中同一 BTB 索引时，顺序上最后的最高有效 lane 留在表中，即最年轻提交指令获胜。查询为纯组合读取，时钟沿发生的训练从下一周期才可见。

JAL 只更新统计，JALR 每次提交都会用实际目标刷新 BTB。仿真协议检查拒绝非控制流训练，并要求 JAL 和 JALR 的实际 taken 恒为一。预测器始终接受全部训练 lane，不提供 ready 信号。

## 统计与接线

模块分别维护 conditional、JAL、JALR 和全部 control 的 `correct`、`total` 32-bit 计数器。每个有效训练 lane 都使所属类别和 control 的 total 加一；预测 next PC 等于实际 next PC 时，对应 correct 同时加一。多个 lane 在同周期按数量累加，溢出按 32-bit 自然回绕。单纯查询不会改变统计。

查询端接取指预译码产生的 `op`、`pc` 和已经符号扩展的 `immediate`。预测得到的 next PC 随指令进入 Fetch Queue，随后写入 ROB 的 `alloc_predicted_next_pc_i`。提交端再把 ROB 保存的预测值与执行得到的实际值送回训练接口。

`make predictor-lint` 使用 Icarus、Verilator 和 Yosys 检查 1/2/4 路配置及 Verilog 2005 可综合性。`make predictor-unit` 覆盖复位、六种条件分支、饱和、alias、JAL 地址计算、BTB 命中与替换、多 lane 冲突、统计和协议错误；两者分别纳入总 `make lint` 与 `make unit`。
