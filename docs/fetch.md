# 参数化取指流水线

`rv32_fetch_pipeline` 连接 L1 指令缓存、预译码器、分支预测器和后续 Decode 阶段。`FE_WIDTH` 控制每个缓存响应最多生成的指令数，`BE_WIDTH` 只控制预测器的提交训练端口；二者分别支持 1、2、4，可以独立配置。复位入口 PC 固定为 0，所有 packed bus 的 lane 0 都表示程序顺序中最老的指令。

## 请求与 Cache line 拆分

流水线维护下一请求 PC，并用一个固定 4 项的请求跟踪队列记录已经被 I-Cache 接受但尚未返回的 PC。跟踪队列允许连续四拍发出请求，同时保证响应只能与最老请求配对。无匹配项或 PC 不匹配的响应视为旧路径响应，直接握手丢弃，不进入 Fetch Queue。

I-Cache 每次返回包含响应 PC 的 128-bit line。流水线从 `PC[3:2]` 指定的 word 开始，最多提取 `FE_WIDTH` 条指令，但不会跨越 16-byte line。例如四路前端从 line 内偏移 `0x0c` 开始时只生成一个有效 lane，下一请求从下一条 line 开始。这样跨行取指由两个有序响应完成，不需要在 I-Cache 内拼接。

## 预译码与预测

每个候选 lane 使用现有 `rv32im_decoder` 生成操作码和立即数，再组合查询内置的 `rv32_branch_predictor`。普通指令的预测下一 PC 为 `PC+4`；条件分支、JAL 和 JALR 保存预测器给出的下一 PC。

流水线按 lane 顺序选择第一个预测 taken 的控制流指令，只将该 lane 及其之前的连续前缀写入 Fetch Queue，并把下一请求 PC 改为预测目标。已经进入 I-Cache 的更年轻顺序请求通过 `icache_flush_o` 清除。预测不跳的条件分支和 BTB miss 的 JALR 不截断 bundle，之后若执行结果不符，由 ROB 的外部 redirect 恢复。

预测器训练端直接接收 `BE_WIDTH` 路提交信息，统计端口原样导出。取指冲刷不会清空 BHT、BTB 或统计；只有 reset 会重置预测器状态。

## Fetch Queue 与回压

Fetch Queue 是默认 8 项的指令级环形 FIFO，容量可通过 `FETCH_QUEUE_ENTRIES` 和 `FETCH_QUEUE_INDEX_WIDTH` 调整。容量必须是 2 的幂且不少于 `FE_WIDTH`。每项保存：

- 指令 PC；
- 原始 32-bit 指令；
- 预测下一 PC；
- I-Cache 错误标志。

输出 valid 总是从 lane 0 开始的连续前缀。后续阶段可以通过 `fetch_ready_i` 接收任意连续前缀，因此 FE 和 BE 宽度不同时不必整包消费。非连续 ready 属于协议错误。队列支持同周期多项出队和一次 Cache 响应的多项入队；响应 ready 会计入本周期出队释放的空间，因此满队列也能无气泡地完成等量替换。未被消费的最老项及其全部元数据保持稳定。

## Redirect、旧响应与错误

外部 `redirect_valid_i` 优先于请求、响应、预测和队列出队：同周期立即屏蔽前端输出，在上升沿清空 Fetch Queue 与请求跟踪队列，并从 `redirect_pc_i` 重新开始。`icache_flush_o` 同时通知 I-Cache 删除其内部旧路径事务。

预测 taken 只清除更年轻的请求跟踪项，不删除 Fetch Queue 中已经排在分支之前的指令。I-Cache flush 后若仍出现迟到响应，PC 匹配保护会将其丢弃。所有正常请求和 redirect PC 必须按 4 字节对齐。

I-Cache 错误生成一个指令值为零、错误位为一的 Fetch Queue 项，并停止继续请求。该项供后续 Decode/ROB 转换为精确异常；只有 reset 或外部 redirect 会解除停止状态。

## 验证

`make fetch-lint` 对全部 9 种 FE/BE 宽度组合执行 Icarus、Verilator 和 Yosys 检查。`make fetch-unit` 覆盖顺序及跨行取指、部分消费、队列满与环回、条件分支、JAL、JALR、redirect、旧响应、Cache 错误、非法参数和协议错误，并连接真实 I-Cache 与 50 周期主存验证 miss、回填和预测冲刷。两个目标分别纳入总 `make lint` 与 `make unit`。
