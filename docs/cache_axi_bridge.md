# L1 Cache 与 AXI4-Lite 桥接

`rv32_l1_cache_axi_bridge` 连接 I-Cache、D-Cache 与 32 位 AXI4-Lite 主接口。Cache 侧保留 128 位整行 ready/valid 协议，一行固定为 16 字节；桥接层把一次行请求转换为四个顺序的 32 位读或写事务。模块由 `rv32_l1_cache_arbiter` 和 `rv32_cache_axi4_lite_adapter` 组成，顶层仅负责两者接线。

## 仲裁与请求保持

仲裁器在 I、D 同拍请求时优先选择 D 侧。同一行事务未收到响应并完成响应握手前，不接收另一侧请求；若下游暂时未能接收被选请求，仲裁器锁存选择，防止另一侧新请求改变当前选择。事务归属保存在 arbiter 中，行响应的数据和错误位只对发起 Cache 侧有效。响应 ready 来自对应 Cache，因此回压会保持响应，并阻止后续行请求进入桥接层。

## AXI4-Lite 转换

adapter 在接收行请求时锁存地址、写数据和 16 位 byte enable。地址按 16 字节对齐，四个 AXI beat 的地址依次为行基址加 0、4、8、12。读事务逐个执行 AR 握手及对应 R 握手，并按低地址字在低位的顺序组装 128 位行数据。

写事务逐 beat 发出 AW 和 W。两通道的 valid/ready 独立跟踪：任一通道先握手后，其地址或数据保持不变，另一通道仍可等待。每个 WSTRB 对应 cache byte enable 的四位切片；该 beat 的 AW 与 W 均握手后，adapter 等待 B 响应，再开始下一 beat。一次只存在一个未完成 AXI beat。

首个非 OKAY 的 RRESP 或 BRESP 结束当前行事务，并向原 Cache 返回错误。读错误的整行数据清零；写错误不继续发送后续 beat，已成功完成的前序 beat 不回滚。成功写响应的读数据为零。Cache 响应自身受 ready/valid 背压约束。

## 接线与验证

I-Cache 的 `memory_request_*` / `memory_response_*` 接到顶层 `i_*` 端口，D-Cache 对应信号接到 `d_*` 端口；`ar*`、`r*`、`aw*`、`w*`、`b*` 直接连接官方 AXI4-Lite RAM。复位需同时作用于 Cache、桥接层和存储器。桥接层串行处理整行事务，不提供 burst，也不允许多笔 AXI outstanding 请求。

`make cache-bridge-lint` 检查 Verilog 2005 语法、层次及综合结构。`make cache-bridge-unit` 测试 D 优先仲裁、四拍读写地址和数据顺序、字节掩码、AW/W 分离握手、响应背压以及 AXI 错误回传。
