# 参数化整数保留站

## 功能

`rv32_integer_reservation_station` 缓冲已经重命名的 RV32I 整数、分支和跳转指令，等待源物理寄存器就绪后按程序年龄选择并送往整数 ALU。默认包含 8 个表项；`BE_WIDTH` 为 1、2 或 4 时，每周期最多原子接收和发射相同数量的指令。所有跨模块数组均压平成 packed bus，lane 0 位于最低位。

保留站借鉴 SORA ALU RS 的操作数捕获、广播唤醒、oldest-ready 和阻塞请求锁定结构，但依赖关系使用物理寄存器号而不是 ROB tag。SORA 的单项 dispatch、单 CDB、单 issue 和全局 flush 也分别扩展为多路原子 dispatch、多路写回广播、多执行端口和选择性 ROB tail rollback。

## 表项与分配

每个表项保存 busy、操作码、PC、立即数、完整 ROB tag，以及左右操作数的 ready、32 位值和物理寄存器号。`dispatch_valid_i` 是只标识 INT、BRANCH 和 JUMP lane 的稀疏掩码，`dispatch_fire_i` 表示整个后端 bundle 已被所有目标资源原子接受。保留站按 lane 顺序将有效指令写入最低编号的可用槽位，不要求目标掩码本身是连续前缀。

`dispatch_ready_o` 根据当前目标 lane 数量判断是否能够完整接收，不允许部分分配。已经在本周期完成 issue 握手的槽位也计入可用容量，因此满站时只要执行端口接受了足够多的旧请求，就能在同一上升沿用新指令覆盖这些槽位。新分配优先于旧表项删除和普通唤醒更新。

尚未就绪的 dispatch 操作数会检查同周期广播；物理编号匹配时直接捕获广播值，避免丢失发生在分配边界上的写回。新表项在该上升沿之后进入选择，因此最早在下一周期 issue。

## 广播唤醒与选择

`broadcast_valid_i`、`broadcast_phys_i` 和 `broadcast_value_i` 提供最多 `BE_WIDTH` 路已被 ROB 接受的物理寄存器写回。每个等待操作数比较完整物理寄存器号，匹配后置 ready 并保存值。物理寄存器 0 不需要广播，也不允许作为未就绪依赖。

广播同时形成组合 effective ready/value。已经驻留的表项可以在广播到达的同一周期参加 issue 选择，输出操作数直接使用旁路值；若请求当周期没有握手，该值会在上升沿写入表项，供锁定请求稳定保持。

选择逻辑取 ROB tag 的槽位 index，计算它相对 `rob_head_index_i` 的环形距离。每个未锁定端口依次选择尚未被其他端口占用的最小距离表项；距离相同时选择较低的保留站槽号。generation 不参与年龄计算，因为同一 ROB 槽位不可能同时存在两个 live 指令，但完整 tag 会随请求传给 ALU。

## Issue 回压

每个 issue lane 对应一个独立整数 ALU ready/valid 端口。`issue_valid_o && issue_ready_i` 成立时删除对应表项。若 valid 为高而 ready 为低，该端口锁定当前槽位；后续周期不受 ROB head 移动、其他表项唤醒或其他端口握手影响，请求的 op、操作数、PC、立即数和 ROB tag 保持稳定。

锁定槽位先占用选择集合，其余未阻塞端口继续从剩余 ready 表项中选择，因此一个 ALU 的完成端回压不会停止其他 ALU。锁定请求握手后解锁；若同一槽位被同周期 dispatch 复用，新表项不会继承旧锁。

## 恢复与清空

分支恢复期间 `recover_i` 屏蔽 dispatch 和全部 issue 请求。ROB 每周期通过 `rollback_valid_i` 和完整 `rollback_tag_i` 给出被撤销的年轻指令；保留站删除匹配表项并清除指向它的端口锁。已经发射的年轻指令不再占用 RS，因此找不到对应 rollback tag 是正常情况。

未出现在 rollback bundle 中的表项和锁保持不变，错误分支之前的未完成指令可以在恢复结束后继续执行。`flush_i` 用于清空整个后端，会删除全部表项和锁。顺序状态优先级固定为同步 reset、全局 flush、选择性 recovery、正常 issue/dispatch/wakeup；三种屏蔽状态下 valid/ready 请求立即无效。

## 接线与验证

decode/rename/dispatch 流水把 rename 给出的源物理编号和 ready、PRF 读值、ROB allocation tag、PC、立即数和操作码送入 dispatch 端。ROB 的 `head_index_o` 连接年龄基准，rollback 端直接连接选择性恢复接口。整数 ALU 连接 issue 端，后续完成网络把仅由 ROB 接受的写寄存器结果广播到本模块。

仿真协议检查拒绝非法参数、容量不足时强制 dispatch、非法操作码或物理编号、重复物理写回、重复 issue 选择、无效锁和 occupancy 不一致。单元测试覆盖定向边界，并使用独立 Python 模型在 4 项单发射、8 项双发射和 16 项四发射配置下进行固定 seed 的逐周期随机差分。
