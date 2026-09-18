# Decode、Rename 与 Dispatch 流水线

`rv32_decode_rename_dispatch` 位于 Fetch Queue 和乱序后端资源之间。模块按 `BE_WIDTH` 实例化译码器，并在内部连接 RAT/RRAT/free list 与物理寄存器文件；ROB、整数/乘法/除法/LOAD/STORE 保留站及 LSQ 通过压平总线连接。`FE_WIDTH` 和 `BE_WIDTH` 分别支持 1、2、4，lane 0 始终是程序顺序中最老的指令。

## 连续前缀与资源检查

模块每周期只考察前 `min(FE_WIDTH, BE_WIDTH)` 个 Fetch lane，并从 lane 0 开始顺序扫描。每条候选指令一定需要一个 ROB 项；写逻辑寄存器时还需要一个空闲物理寄存器。整数、分支和跳转需要 INT RS，乘除法需要各自的 MDU RS，load/store 则同时需要对应访存 RS 与 LSQ。

扫描使用各结构周期开始时的 occupancy 和 free count。当前 lane 加入后若任一容量不足，扫描在该 lane 停止，不能跳过它接收更年轻指令。该判断故意不借用同周期 issue 或 commit 释放的槽位，从而避免 ready 组合环并保持资源协议简单。选中前缀仍须等待 ROB、rename、LSQ 及所有目标 RS 的 ready；只有全部就绪时统一 `dispatch_fire_o` 才置位，Fetch ready、ROB allocation 和各目标 dispatch 在同一上升沿原子生效。

## 译码、重命名与操作数

每个候选 lane 使用 `rv32im_decoder` 产生操作码、类别、寄存器编号、立即数和访存属性。选中 bundle 整体送入 `rv32_rename_unit`，因此较年轻 lane 可以看到较老 lane 刚分配的新物理寄存器，正确表达 RAW 和 WAW 关系。新目的寄存器标为未就绪，后续依赖项在保留站中等待完成广播。

rename 返回的两个源物理编号直接读取内部 PRF。PRF 与 rename ready 记分牌都包含同周期 writeback 旁路，因此恰好在 dispatch 周期返回的结果能够直接作为 ready/value 写入保留站。reset、全局 flush 或 ROB recovery 会立即屏蔽新 dispatch；恢复期间 ROB 的 rollback 元数据仍传给 rename 以恢复 RAT 并回收错误路径物理寄存器。

## 路由与 ROB-only 指令

路由掩码允许同一 bundle 中不同类别形成稀疏目标 valid，但 ROB allocation 和 Fetch ready 始终是连续前缀：

- INT、BRANCH、JUMP 进入整数保留站；
- MUL 和 DIV 进入对应 MDU 保留站；
- LOAD 和 STORE 同时分配 LSQ 与对应访存保留站，LSQ 产生的 tag 同时写入 ROB 和访存 RS；
- FENCE、HALT、ECALL、EBREAK、非法指令及取指错误只进入 ROB。

ROB-only 项在分配时直接 complete。FENCE 和 HALT 不产生异常；取指访问错误、非法指令、EBREAK 和 ECALL 分别记录异常原因 1、2、3 和 11。对应 `tval` 分别为 PC、原始指令、PC 和零。异常只随 ROB 项按序提交，不在 dispatch 阶段产生架构副作用。

## 接线与验证

Fetch 侧连接 `rv32_fetch_pipeline` 的 valid、ready、PC、原始指令、预测下一 PC 和错误标志。公共 dispatch 元数据与类别 valid 掩码连接各保留站；ROB 和 LSQ 的组合 allocation tag 返回本模块后再随同一 bundle 分发。ROB commit fire、rollback 和完成网络 writeback 分别连接内部 rename/PRF 的提交、恢复和写回端口。

`make dispatch-lint` 对全部 9 种 FE/BE 宽度组合执行 Icarus、Verilator 和 Yosys 检查。`make dispatch-unit` 覆盖类别路由、RAW/WAW、PRF 旁路、精确异常、ROB/RS/LSQ/free-list 资源不足、非连续输入协议，并用真实 ROB、INT/LOAD/STORE RS 和 LSQ 验证混合 bundle 及误预测回滚。两个目标均纳入总 `make lint` 和 `make unit`。
