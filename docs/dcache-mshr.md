# 两项 MSHR 与同一行请求合并

`rv32_l1_data_cache.MSHR_ENTRIES` 支持 1/2，单独实例默认 1；`student_top.DCACHE_MSHR_ENTRIES` 默认 2。关闭 nonblocking 或 hit-under-miss 时顶层使用单项控制器。两项模式仍使用原有 S0/S1/S2、响应寄存器及 skid 队列，无争用 Load 命中保持三周期，LSQ/完成网络的快速返回连接不变。

## 状态与请求顺序

每项 MSHR 保存完整行地址、预留 way、原 victim 地址与 128 位数据、写回/读取的 sent/done/error 位、128 位 refill 缓冲和累计 dirty 位。每行有四项请求 FIFO；每项保存 CPU 请求 ID、完整 ROB tag、行内字偏移、读写类型、写数据及字节掩码。CPU 的四个在途请求与两个 MSHR 是不同资源。

S2 miss 命中已有 MSHR 的完整行地址时加入该 FIFO，最多合并四笔；不匹配时分配空闲 MSHR。两项可同时处理不同 set 的 miss。同一 set 的不同行请求保守等待原预留释放，避免两个 victim 相互替换；同一行请求可以继续进入查询流水线并合并。分配时撤销选中 victim way 的 Store 目录证明；已证明 Store 不允许转入 MSHR。

查询阶段的 `miss_event_o` 包括稍后合并的请求；它与新分配 MSHR、实际主存 refill 是不同计数。评估并行 miss 应分别观察分配、合并、占用与主存握手，不能把全部查询 miss 当成额外主存流量。

FIFO 按 cache 接收顺序处理。Load 读取当前 refill 缓冲；Store 按掩码修改该缓冲，之后同一行 Load 能看到它。每笔返回仍独立携带请求 ID 和完整 ROB tag。最后一笔进入响应队列时安装最终行、标签和 dirty 位并释放 MSHR；若同周期又合入一笔，则保留该项并继续处理，不能提前安装或释放。响应队列回压不会丢失 waiter，两个已完成 MSHR 轮转共享返回端。

## 桥接事务关联

Dcache 主存请求新增一位 `memory_request_id_o`，桥接在 D 侧握手时保存它。并行桥的两个读 owner FIFO 槽同时保存 MSHR ID，独立的写 owner 槽保存写回 ID；返回的 `d_response_id_o` 与 `d_response_write_o` 一起定位所属事务。串行桥也保存该 ID。ID 不放到外部 AXI4-Lite 接口上；adapter 保持读事务和各自四个 beat 的顺序，读写通道可以独立完成。

MSHR 发出自身写回请求后即可发出 refill，与写回确认重叠；多个待发请求优先选择可发出的读取，再选择写回。Dcache 和仲裁器分别锁定受回压的事务与 owner，直到握手，禁止其他 MSHR 或 Icache 请求改变其字段。MMIO 仍等桥内先前读写全部完成后进入。

## Refill、错误与 SRAM

每项独立接收读、写返回。只有自身读取结束且其可选写回结束后，才允许产生任何 waiter 返回；任一失败则该项全部 waiter 返回错误，不安装新行，也不影响另一项。写回失败保留原 valid/dirty victim；写回成功而 refill 失败保留原 valid/clean victim。后续重试仍从原行取得正确数据。桥接继续收完发生错误事务的全部 R/B beat，并仅把聚合错误交给对应 MSHR。

已完成的 MSHR 轮转仲裁单端口阵列，每周期至多安装一行。安装与 S2 Store 命中写入互斥，FIFO 中间的 Store 仅修改 refill 缓冲。安装后有一拍重读 S1，刷新标签、valid/dirty 快照和旁路状态。

官方 FakeRAM 在禁用或写入时不保证读输出。因此，MSHR 分批返回但不写阵列的周期也持续读取当前 S1 set；否则返回队列填满后恢复 S1，会使用未定义 tag。定向测试把已证明 Store 停在 S1，同时制造合并返回与回压；关闭这段持续读取的负对照必须触发保护断言。

## 恢复与验证

Cache 不取消已经接受的 Load；完整 ROB tag 随每个 waiter 返回，由 LSQ 按原身份及回滚状态决定丢弃。Store 仍受 LSQ 提交与不可失败证明约束。MSHR 在后端读写均完成且所有 waiter 已交给响应队列后才复用，CPU 请求 ID 在原响应被消费前不得复用。系统 reset 必须同时复位 cache、bridge 和主存协议状态。

`make mshr-unit` 覆盖 1/2/3/4 way、不同主存延迟、目录别名、后续 Store 确认、合并 Load/Store 掩码顺序、双完成仲裁、回压、复位、两种读写返回顺序和写回/refill 错误。桥接测试同时放入两个 D 读与一个 D 写，检查每个 ID、数据、错误和 MMIO 顺序；三个负对照检查未知 ID、丢失桥接 ID和 S1 读口停读。`make mshr-lint` 检查两项模式的 Verilog 2005 语法、严格 lint 和综合结构；这些目标已接入完整 `unit`/`lint`。
