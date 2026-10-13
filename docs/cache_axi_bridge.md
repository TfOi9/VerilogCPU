# L1 Cache 与 AXI4-Lite 桥接

`rv32_l1_cache_axi_bridge` 连接 I-Cache、D-Cache、MMIO Store 与 32 位 AXI4-Lite 主接口。Cache 侧保留 128 位整行 ready/valid 协议，一行固定为 16 字节；桥接层把一次行请求转换为四个顺序的 32 位读或写事务。MMIO 侧是单个 32 位写事务。模块由 `rv32_l1_cache_arbiter` 和 `rv32_cache_axi4_lite_adapter` 组成，顶层仅负责两者接线。

## 仲裁与请求保持

仲裁优先级为 MMIO、D-Cache、I-Cache。MMIO 只会由 ROB 头部 Store 产生，最高优先级避免结束事务被 Cache refill 长期阻塞。同一事务未收到响应并完成响应握手前，不接收其他请求；若下游暂时未能接收被选请求，仲裁器锁存选择。事务归属保存在 arbiter 中，响应只对原发起方有效，响应回压会阻止后续请求。

## AXI4-Lite 转换

adapter 在接收行请求时锁存地址、写数据和 16 位 byte enable。地址按 16 字节对齐，四个 AXI beat 的地址依次为行基址加 0、4、8、12。内部状态为 IDLE、READ、WRITE、RESPONSE。每次仍只处理一个行事务，但允许行内最多四个字请求在途。

读通路用 `ar_count` 和 `r_count` 分别记录已接受地址和已回收响应。AR 无需等待上一字的 R，即可发出下一字；只有存在已接受但未回收的地址时才拉高 RREADY。按 AXI4-Lite 响应顺序，把第 n 个 R 写入整行第 n 个字。最后一个 R 握手后才生成 Cache 响应。

写通路用 `aw_count`、`w_count`、`b_count` 独立记录地址、数据和响应。AW 可以领先 W 四拍，W 也可以领先 AW 四拍；各自只有握手才推进索引，因此未握手的 VALID 和负载保持稳定。每个 WSTRB 对应 cache byte enable 的四位切片。只有同时存在已接受 AW 和 W、且尚未消费 B 的写事务时才拉高 BREADY；B 的回收可与后续 AW/W 握手重叠。最后一个 B 握手后才生成 Cache 响应。

MMIO 的字数限制为 1，保留原始的 4 字节对齐地址。写数据和 WSTRB 位于输入总线低位，因此 `0x80000000` 结束 Store 恰好产生一次 AW、一次 W 和一次 B，不产生地址 `+4/+8/+12` 的额外写入。独立 AW/W 背压、B 等待及上游响应背压期间，仲裁器始终保持 MMIO 的归属。ROB 头部约束仍由核心和 LSQ 保证。

## 错误与复位

任意非 OKAY 的 RRESP 或 BRESP 都置位粘滞错误标志。即使首字报错，也继续完成本行四字的请求和响应，全部回收后只向原发起方返回一次错误；不会提前转交总线，也不会撤销已被背压挂住的 VALID 或丢下未配对的 AW/W。错误读数据整行清零，所有写响应的读数据也为零；响应 VALID、错误和数据在上游握手前保持不变。

完整收尾针对 Cache 的普通内存行，不承诺错误写入的事务原子性：部分或全部字可能已经产生副作用，桥接层不回滚。MMIO 不使用四字行模式，因此错误收尾不会导致额外 MMIO 写入。

复位立即抑制所有握手输出，并在时钟边沿清空状态和计数。系统必须同时复位 AXI 从设备，取消旧请求及响应；本接口没有 transaction ID，不能在只复位桥接层、保留旧从设备响应的情况下区分新旧事务。

## 接线与验证

I-Cache 的 `memory_request_*` / `memory_response_*` 接到顶层 `i_*` 端口，D-Cache 对应信号接到 `d_*` 端口，LSQ 的 MMIO Store 接到 `m_*` 端口；`ar*`、`r*`、`aw*`、`w*`、`b*` 直接连接官方 AXI4-Lite RAM。接口不增加 AXI burst 或 ID，依赖从设备在各响应通道内保持请求顺序；下游只接受单个在途请求时也能通过 READY 背压正常工作。

`make cache-bridge-lint` 检查 Verilog 2005 语法、层次及综合结构。`make cache-bridge-unit` 包含原有仲裁测试和八个种子的并发协议测试：四字在途、AW/W 双向领先、请求/响应重叠、每个字的错误、错误发生时仍有请求未发送、错误后的下一事务、字节掩码、MMIO 不同字地址与全部 16 种 WSTRB、I/D/MMIO 响应隔离、其他客户端 READY 已拉高时的响应背压，以及共享复位。覆盖计数未达到要求时测试失败。
