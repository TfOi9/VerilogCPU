# Bimodal 与 BTB 分支预测器

`rv32_branch_predictor` 是组合查询、时钟沿训练的多路分支预测器。`FE_WIDTH` 决定同周期查询数，`BE_WIDTH` 决定同周期提交训练数，二者分别支持 1、2、4。所有跨模块数组均压平成 packed bus，lane 0 位于最低位。预测器没有 backpressure，也不响应分支恢复 flush；错误预测不会清除已经学习的状态，只有同步 reset 会清空表项和统计。

## 预测结构

条件分支共用 64 项 BHT。`PC[7:2]` 直接选择一个 2-bit 饱和计数器，高地址位不构成标签，因此不同 PC 可以有意地 alias 到同一项。计数器复位为 `00`，`00`、`01` 预测不跳，`10`、`11` 预测跳转。预测跳转时下一 PC 为 `pc + immediate`，否则为 `pc + 4`。BEQ、BNE、BLT、BGE、BLTU 和 BGEU 使用完全相同的表项和规则。

返回阶段的 JAL 始终预测跳转并直接计算 `pc + immediate`。JALR 使用 16 项直接映射 BTB，`PC[5:2]` 选择表项，每项保存 valid、完整 32-bit PC 标签、目标和 conditional 标志。标签命中时预测跳转到保存目标；未命中时预测不跳并使用 `pc + 4`。完整 PC 标签避免同索引的不同指令产生假命中。

BTB 现在也记录实际 taken 的条件分支和 JAL，与 JALR 共用容量。新增 `early_query_valid_i/early_query_pc_i` 地址查询口，每个 lane 在完整 tag 命中且目标对齐时给出 `early_taken_o/early_target_o`；conditional 项还必须得到 BHT 的 taken 预测。该端口不依赖指令译码，供取指请求阶段提前选择目标。原译码查询口保留，用于返回阶段校正早期猜测。

无效查询和非控制流操作输出全零。各查询 lane 相互独立，预测结果不负责决定 fetch bundle 的截断位置；后续取指流水线应选择程序顺序中的第一个 `prediction_taken_o`。

## 提交训练与冲突

当前 CPU 连接 ROB 的 `predictor_update_*`，在控制流完成被接受时训练，使用 ROB 保存的操作码、PC、预测 next PC，以及执行返回的实际 next PC/taken。因此统计可能包含错误路径，不能解释为严格退休分支准确率。本轮保持该训练时机，未更改 ROB 更新语义。

训练 valid 允许稀疏分布。同周期多个条件分支命中相同 BHT 索引时，从低 lane 到高 lane 逐项更新临时计数器，因此每次训练都生效并保持上下界饱和。同周期多个 taken 控制流命中同一 BTB 索引时，最后的最高有效 lane 留在表中；当前完成端 lane 并不保证按退休年龄排序。查询为纯组合读取，时钟沿发生的训练从下一周期才可见。

JAL、JALR 和实际 taken 的条件分支用实际目标刷新 BTB；条件分支不跳时仅更新 BHT/统计，避免把 fall-through 写成 BTB 跳转目标。仿真协议检查拒绝非控制流训练，并要求 JAL 和 JALR 的实际 taken 恒为一。预测器始终接受全部训练 lane，不提供 ready 信号。

## 统计与接线

模块分别维护 conditional、JAL、JALR 和全部 control 的 `correct`、`total` 32-bit 计数器。每个有效训练 lane 都使所属类别和 control 的 total 加一；预测 next PC 等于实际 next PC 时，对应 correct 同时加一。多个 lane 在同周期按数量累加，溢出按 32-bit 自然回绕。单纯查询不会改变统计。

译码查询端接取指预译码产生的 `op`、`pc` 和已经符号扩展的 `immediate`；早期查询端接下一取指请求的逐 lane PC。返回阶段预测 next PC 随指令进入 Fetch Queue，再写入 ROB 的 `alloc_predicted_next_pc_i`。ROB 接受控制流完成时将预测值与实际值送回训练接口。

`make predictor-lint` 使用 Icarus、Verilator 和 Yosys 检查 1/2/4 路配置及 Verilog 2005 可综合性。`make predictor-unit` 覆盖复位、六种条件分支、饱和、alias、JAL 地址计算、BTB 命中与替换、多 lane 冲突、统计和协议错误；两者分别纳入总 `make lint` 与 `make unit`。
