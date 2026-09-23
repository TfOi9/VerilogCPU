# Load/Store Queue

`rv32_load_store_queue` 保存未完成的访存指令。默认 8 项，每项记录完整 ROB tag、类型、宽度、无符号标志、地址、store 数据、执行和提交状态。LSQ tag 默认由 3 位槽索引及 2 位 generation 构成；槽位复用时 generation 递增，地址、数据与回滚输入同时核对 ROB tag 和完整 LSQ tag。分配按 dispatch lane 顺序选择空槽，并对整个 bundle 原子接收。

## 访存顺序与转发

LOAD 和 STORE 保留站可以同时提出地址，但 LSQ 每周期只接收一条，优先接收相对 ROB head 更老的指令。store 地址和数据分别到达，两者齐备后报告执行完成。load 必须等待全部更老 store 的地址已知，然后逐字节寻找覆盖目标字节的最近更老 store。全部字节可转发时直接组合并扩展；部分覆盖或数据未就绪时保守等待；无重叠时访问 D-Cache。

普通 RAM 地址范围为 `0x00000000..0x0fffffff`，访问必须按宽度自然对齐。`0x80000000` 是单独的退出 MMIO 地址，只允许 32 位 Store；MMIO Load、SB/SH、其他 RAM 范围外地址以及非对齐访问均生成精确地址异常且不发出存储请求。非对齐异常原因为 load/store 4/6，其他地址错误为 5/7，`tval` 保存原始有效地址。

## 请求路由与提交

LSQ 对外保留单笔 ready/valid 请求和响应协议。`cache_request_mmio_o=0` 表示普通 RAM 请求，应送往 D-Cache；`cache_request_mmio_o=1` 只与合法退出 Store 同时出现，集成层必须绕过 D-Cache 并送往 AXI4-Lite 写通道。退出请求固定输出地址 `0x80000000`、原始 32 位 store 数据和 `4'hf` byte enable。

store 首次完成后仍留在 LSQ。只有它成为 ROB lane 0 的提交候选，才会发出 RAM 或 MMIO 写请求。请求在回压期间保持稳定；成功响应置位 `write_done`，随后才拉高对应 `commit_ready_o`。写错误在首次执行完成之后到达，LSQ 会补发 cause 7 的异常完成，等待 ROB 保存晚到异常后才允许退休。未来 AXI 路由层把 MMIO 的 B 通道状态转换为现有 `cache_response_valid_i` 和 `cache_response_error_i`，因此 LSQ 对两类写使用相同完成状态机。

load 请求可在满足顺序约束后乱序发出。读响应按原地址选择字节或半字并执行符号或零扩展，再进入单项完成缓冲。读错误生成 cause 5。普通 store 数据按字内偏移移位并产生相应 byte enable；退出 MMIO Store 始终为完整字写。

## 恢复与接线

选择性恢复阻止新请求和完成握手，并按完整 tag 删除错误路径项。已发出的错误路径 load 被标记为待丢弃，响应在恢复结束后排空，不污染复用槽。全局 flush 清空本地状态；系统集成不得用它取消已经交给存储系统的架构 store。

LSQ 分配端连接 dispatch 和 ROB allocation tag；地址、store 数据端连接两个访存保留站；完成端连接完成仲裁网络；ROB 的提交候选、提交 fire、异常状态和回滚 tag 连接提交与恢复端口。存储路由层依据 `cache_request_mmio_o` 在 D-Cache 与退出 MMIO 之间选择目的地，并把选中目的地的响应返回 LSQ。

定向测试覆盖未知 store 地址、逐字节转发、部分覆盖、不同宽度与符号扩展、回压、tag 复用、恢复、RAM 最后合法字、RAM 上界、合法 MMIO Store、非法 MMIO 宽度和地址，以及 MMIO 成功与错误响应。LSQ 与 ROB 的集成测试继续核对 load 写回、store 顺序提交和晚到异常。
