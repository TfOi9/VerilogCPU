# 乘除法保留站

## 功能与接口

`rv32_multiply_reservation_station` 和 `rv32_divide_reservation_station` 分别缓冲已经重命名的 RV32M 乘法与除法指令。两个公共模块复用单发射保留站核心，并分别封装现有的三级流水乘法器和迭代除法器。默认每站包含 4 个表项；前端可以按 `BE_WIDTH` 路原子 dispatch，但每站每周期最多向一个执行单元发射一条指令。

dispatch 接口使用稀疏 valid 掩码，lane 0 位于压平总线最低位。每项保存操作码、完整 ROB tag，以及两个源操作数的 ready、value 和物理寄存器号。乘法站只接受 `MUL`、`MULH`、`MULHSU` 和 `MULHU`，除法站只接受 `DIV`、`DIVU`、`REM` 和 `REMU`。PC、立即数和目的物理寄存器不进入本站；后续完成网络根据响应 ROB tag 定位 ROB 项和写回目标。

## 分配、唤醒与选择

两个保留站按照 dispatch lane 顺序把有效指令写入最低编号空槽，不允许部分接收 bundle。已经在本周期与执行单元握手的槽位计入可用容量，因此满站时可以在同一上升沿完成 issue 和槽位复用。新分配项在下一个周期才参加选择。

驻留项和新 dispatch 项都会检查最多 `BE_WIDTH` 路写回广播。未就绪源的物理寄存器号匹配时，保留站在同一周期旁路广播值并将源标记为就绪；驻留项可以在该广播周期立即参加 issue。

选择器使用 ROB tag 的 index 与 `rob_head_index_i` 计算环形距离，选择距离最小的 oldest-ready 项，距离相同时选择较低槽号。完整 generation 随请求送入执行单元，但不参与年龄比较，因为同一 ROB index 不会同时存在两个 live 指令。

## 执行与回压

乘法站连接完全流水化乘法器。没有完成端回压时，它可以每周期移除一个 ready 表项并接受下一条乘法请求。除法站连接单请求迭代除法器；迭代期间及未消费结果存在时，执行请求 ready 为低，其他除法指令继续保留在队列中。

当选中请求未被执行单元接受时，保留站锁定该槽位。后续 ROB head 变化、新操作数唤醒或更老指令出现都不会改变锁定请求的操作码、两个操作数和 ROB tag。请求握手后释放表项和锁。

两个公共模块分别输出独立的 `response_valid_o`、`response_ready_i`、结果和 ROB tag。它们不决定来源优先级；后续完成网络负责在乘、除、整数和访存结果同时有效时仲裁。任一通道被阻塞时，执行单元保持结果和 tag，不覆盖其他完成。

## 恢复与清空

`recover_i` 立即禁止 dispatch 和 issue，并通过 rollback tag 删除尚未发射的错误路径表项。恢复期间执行单元的响应握手被阻塞，已有结果保留。已经发射的年轻请求不会被选择性取消；恢复结束后，它的响应仍携带原 ROB generation，由 ROB 拒绝陈旧 tag 并由完成网络排空。

`flush_i` 用于整个后端清空，同时删除所有保留站表项并清除乘法流水线或除法迭代状态。顺序状态优先级为同步 reset、全局 flush、选择性 recover、正常 issue/dispatch/wakeup。

## 参数与验证

`MUL_RS_ENTRIES` 和 `DIV_RS_ENTRIES` 必须为不小于 `BE_WIDTH` 的 2 次幂，index width 必须与容量匹配。`BE_WIDTH` 只允许 1、2 或 4；物理寄存器和 ROB 参数沿用其他后端组件的约束。

单元测试覆盖稀疏分配、广播旁路、ROB 环回年龄、满站同周期复用、乘法连续发射、除法 busy、请求和响应回压、rollback、恢复保持、全局 flush，以及乘除结果同时有效时的无损消费。固定 seed 的 Python 向量覆盖全部八条 RV32M 指令、边界输入和随机输入，并在多组宽度与容量配置下核对结果和 ROB tag。
