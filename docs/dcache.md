# 流水线 L1 数据缓存

`rv32_l1_data_cache` 是可参数化、write-back/write-allocate 的 L1 数据缓存。默认容量为 4 KiB，256 组、1 路、每行 16 字节。`CACHE_SIZE_BYTES`、`NUM_SETS` 和 `NUM_WAYS` 配置容量、组数和相联度，并须满足 `CACHE_SIZE_BYTES = NUM_SETS × NUM_WAYS × 16`；组数须为不小于 2 的 2 的幂。每一路的数据阵列和标签阵列使用官方 `sram_fakeram` 同步 SRAM；valid、dirty 位和每组 round-robin 替换指针由寄存器保存。复位清除这些状态，不初始化 SRAM 内容。

缓存只接受对齐的 32 位 RAM 字访问，地址范围为 `0x00000000` 至 `0x0ffffffc`，对应 256 MiB RAM。地址 `0x80000000` 等 MMIO 不在缓存范围内，应由 LSQ 路由。行偏移为地址低 4 位，`address[4 +: log2(NUM_SETS)]` 选组，其余高位构成标签；`address[3:2]` 选行内的 32 位字。

## 命中流水线

| 上升沿 | 处理 |
| --- | --- |
| N | S0 接收请求及全部写入字段。 |
| N+1 | S0 组号驱动每一路同步 SRAM 读口，S1 保存请求字段以及 valid/dirty 快照；SRAM 输出在沿后成为该请求的行和标签。 |
| N+2 | S2 比较各路标签并保存命中路或替换路、整行数据及元数据。 |
| N+3 | 命中读数或写确认进入响应寄存器；命中写入更新数据 SRAM 和 dirty 位。 |

同步 SRAM 的单周期读延迟包含在三周期命中延迟中。没有停顿或 miss 时，各级可同时处理不同请求，因此命中请求每周期可接收一笔。SRAM 禁用或写入时读数据未定义，运行期间缓存持续重读当前 S1 组；同组 store 后的 S1/S0 查询分别通过写后旁路取得新行，跨组冲突时暂停 S0 查询一拍。这样支持 FakeRAM 的单端口读写时序，同时维持请求顺序。响应回压时各级按 ready 信号停止并保持数据。

命中时选中匹配路。miss 时优先使用首个 invalid 路；所有路均有效时，用该组的 round-robin 指针选择 victim。成功 refill 后指针前进一格。连续访问同组时，已命中的 load/store 和写后 load 均使用 S2 行数据，保证部分字节写掩码以及 store/store、store/load 顺序。

## Miss、写回与主存接线

单笔 miss 控制器只接管 S2 的未命中请求；S0、S1 中已经接收的年轻请求冻结。若选中路有效且脏，先将 `{原标签, 组号, 4'b0}` 对应的整行以 `16'hffff` 掩码写回，收到成功确认后才读取目标行；否则直接读取。写回成功时原行变为 clean。回填成功后安装新标签和数据；store miss 先把写入字节合并到回填行，并标记 dirty。原请求完成后，S1 重新读取阵列，再恢复年轻请求，避免它使用回填前的过期快照。

写回失败时保留原 dirty 行并向当前请求返回错误；回填失败时保留原行，若先前写回成功则该行保持 clean。非字对齐或超出 `0x0ffffffc` 的字请求返回错误，不访问主存，也不计入命中或未命中。有效请求在首次标签判断时恰好产生一个 `hit_event_o` 或 `miss_event_o` 脉冲，重读不重复计数。

Cache 的 128 位 refill/writeback ready/valid 接口保持不变，系统接线时连接 `rv32_l1_cache_axi_bridge` 的 D 侧端口；该桥接层负责 I/D 仲裁并把每行拆成四次 32 位 AXI4-Lite 事务。本地单测直接连接 128 位仿真主存。LSQ 根据 ROB 提交候选发送 store，并在需要时丢弃错误路径 load 的返回值；缓存不设分支 flush 端口。脏数据立即对后续 D-Cache 读取可见，主存中的副本直到驱逐写回才更新。复位须与桥接层及主存一起施加。桥接层的仲裁、AXI 握手和错误处理见 [cache_axi_bridge.md](cache_axi_bridge.md)。

`make dcache-lint` 检查 Verilog 2005 RTL 语法、FakeRAM 层次和综合结构；`make dcache-unit` 运行独立缓存、参数化 2 路冲突替换及 LSQ—D-Cache—主存接线测试。测试包含三周期命中、逐周期吞吐、同组旁路、回压、脏行驱逐、错误、256 MiB 地址边界和固定种子随机一致性，并设置仿真与墙钟 watchdog。
