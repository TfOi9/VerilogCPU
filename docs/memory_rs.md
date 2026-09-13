# LOAD/STORE 保留站

`rv32_memory_reservation_station` 通过 `IS_STORE=0/1` 分别实例化为独立的 LOAD 和 STORE 保留站。两站各有参数化表项、源操作数就绪位和值、物理寄存器号、立即数、ROB tag 和 LSQ tag。输入按 `BE_WIDTH` 路压平；有效 lane 可以稀疏，整个 bundle 只在 `dispatch_fire_i && dispatch_ready_o` 时原子进入本站。

广播端逐路比较未就绪源的物理寄存器号。驻留项可以在广播同周期生成地址或 store 数据，新分配项也会捕获同周期广播。地址由 base 加立即数产生；store 数据有独立的 ready/valid 通道，因此 base 已就绪而数据未就绪时，地址仍能先送入 LSQ。LOAD 站不使用数据通道。

每站按相对 ROB head 的环形距离选择最老的就绪项。地址或数据通道遇到回压时锁定所选项，直到握手，保持 tag 和 payload 稳定。两站同时提出地址时，由 LSQ 按相同年龄规则只接受其中一个；store 数据可并行传输。地址和数据都送达后释放 STORE 站表项，LOAD 站在地址送达后释放。

选择性恢复期间停止分配和输出，用完整 ROB tag 删除本批回滚项。全局 `flush_i` 清空表项和锁定状态。参数检查限制宽度为 1/2/4、容量为不小于后端宽度的 2 次幂，并验证索引位宽。

接线时，dispatch 同一有效 lane 同时分配 ROB、对应保留站和 LSQ，并把 LSQ 返回的 tag 传给保留站和 ROB。保留站广播输入接完成网络的写回广播；地址/数据输出接 LSQ 相应握手端口，`rob_head_index_i` 接 ROB head，恢复输入接 ROB 回滚输出。
