# 参数化重排序缓冲区

## 功能

`rv32_reorder_buffer` 保存所有已分配但尚未提交的指令，并把乱序完成重新组织为按程序顺序提交。模块每周期最多原子分配、接受完成和提交 `BE_WIDTH` 条指令；所有跨模块数组均压平成 packed bus，lane 0 位于总线最低位。分配与提交 lane 按 oldest 到 youngest 排列，回滚 lane 按 youngest 到 oldest 排列。

默认 ROB 包含 32 项，后端宽度为 1。每个 tag 由 5 位槽位索引和 2 位 generation 组成，因此默认宽度为 7 位。`ROB_ENTRIES` 必须是 2 的幂，`ROB_INDEX_WIDTH` 必须恰好覆盖全部槽位，`ROB_TAG_WIDTH` 必须等于索引宽度与 generation 宽度之和。

## 内部结构

ROB 使用 head、tail 和 occupancy 描述循环队列。每项包含 busy、generation、complete，以及 PC、原指令、操作类型、逻辑目的寄存器、新旧物理寄存器、执行结果、预测和实际控制流、LSQ tag、异常原因与异常地址。每个槽位另有 `next_generation`，表示该槽下一次分配时使用的 generation。

`head_index_o` 只读输出当前 head 槽位，供保留站按环形 ROB 距离比较指令年龄；复位期间输出零。年龄比较只需要 index，完成和回滚匹配仍必须使用包含 generation 的完整 tag。

成功分配时，输出 tag 使用 `{next_generation, slot_index}`，表项在上升沿写入该 generation，同时 `next_generation` 加一并按参数宽度自然回绕。完成只有在 busy、索引和 generation 全部匹配且表项尚未 complete 时才被接受。这样，错误路径撤销后迟到的结果以及槽位复用前的旧结果不会修改新表项。

## 分配、完成与提交

allocation 输入必须是从 lane 0 开始的连续有效前缀。模块按周期开始时的 occupancy 判断整个 bundle 是否有空间，不借用同周期提交释放的槽位。只有 `alloc_fire_i && alloc_ready_o` 才在上升沿写入全部有效 lane；不进行部分分配。

completion 的 ready 和 accept 含义不同。正常周期 ready 为高，使完成来源能够交付结果；accept 只对匹配 live tag 的首次完成为高，PRF 和完成广播必须用 accept 作为写入使能。恢复期间 ready 为低，保证更老的在途结果留在执行单元或完成缓冲。恢复结束后，年轻指令的陈旧结果会以 ready 高、accept 低的方式被排空。

commit 组合逻辑从 head 开始选择连续的 complete 前缀。`commit_valid_o` 表示候选项，`commit_fire_o` 还要求当前 lane 和所有更老 lane 的 `commit_ready_i` 为高。只有 fire 项在上升沿释放；因此 store 可以保持在 ROB 头部，直到后续 LSQ 和 D-Cache 确认其架构副作用可以提交。HALT、非法指令、系统指令和访存异常也只在对应 commit fire 时对外生效。

同一正常周期可以提交旧项、完成其他 live 项并分配新项。所有组合输出观察上升沿之前的状态，所以本周期刚完成的 head 最早在下一周期出现在 commit valid 上。head、tail 和 occupancy 在同一上升沿根据实际 commit 与 allocation 数量统一更新。

## 分支恢复

控制流完成携带实际 next PC。ROB 将它与分配时保存的预测 next PC 比较；同周期出现多个误预测时，按相对 head 的距离选择最老分支。误预测完成所在周期已经握手的正常提交、完成和分配仍在该上升沿生效，新分配项属于该分支之后的错误路径，必须一并回滚。

下一周期 ROB 进入注册的 recovery 状态，发出一次 redirect，并暂停 allocation、commit 和 completion。每周期从 tail 前一项开始输出最多 `BE_WIDTH` 个回滚项，直到误预测分支本身为止；分支保留并保持 complete。最后一批年轻项在上升沿删除时同时退出 recovery，不增加空的恢复周期。若分支已经是 tail 前一项，仍保留一个只发 redirect、不含 rollback 项的恢复周期。

状态优先级固定为同步复位、已进入的 recovery、正常周期。复位清空全部表项、指针、occupancy 和 generation；reset 为高时所有有效输出被屏蔽。

## 接线

rename/dispatch 使用 allocation tag，并在同一 bundle fire 时把 PC、指令和重命名元数据写入 ROB。完成仲裁网络连接 completion 端，只有 accept lane 才能同时写 PRF。`commit_fire_o`、rd 和 new physical register 直接连接 rename 的 commit 接口。

恢复时，`recover_busy_o` 连接 rename 的 `recover_i`，rollback 的 writes-rd、rd、new-phys 和 old-phys 直接连接现有回滚接口。rollback tag 和 LSQ tag 提供给后续保留站与 LSQ，用于逐批删除同一批错误路径指令。前端使用 redirect valid 和 redirect PC 重新取指。

`head_index_o` 连接各保留站的 oldest-ready 年龄选择输入。head 在提交上升沿更新，保留站在周期内观察更新前的稳定值；提交只会整体平移 live ROB 窗口，不改变剩余指令之间的年龄顺序。

选择性 tail rollback 不能直接连接 ALU、乘法器和除法器的全局 `flush_i`，否则可能杀死误预测分支之前的更老执行。恢复期间应通过 completion ready 施加回压；恢复结束后，执行单元携带的 generation tag 由 ROB 判断为 live 或 stale。全局 `flush_i` 只留给复位或清除整个后端的场景。

仿真协议检查拒绝非法参数、稀疏 allocation bundle、资源不足时强制 fire、occupancy 溢出、恢复期间正常状态更新以及恢复边界丢失。检查逻辑不进入综合网表。

单元测试除定向边界场景和 Verilog 内部 scoreboard 外，还使用 `tools/generate_rob_vectors.py` 的独立 Python 循环队列模型生成随机提交、分配、occupancy 和 generation tag 期望值，并在 16×1、32×2、64×4 三种配置下逐周期差分。
