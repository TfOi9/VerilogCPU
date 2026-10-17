# Store 驻留证明目录

目录为普通 RAM Store 提供 Cache 命中证明，复用现有的 `request_irrevocable_o` 提前退休协议。它保存行身份与 way 所有权，不保存数据，也不让推测 Store 写入 Cache。

## 内部结构

`STORE_DIRECTORY_ENTRIES` 为零时使用原有 FIFO 驻留提示；为正时必须是二次幂，实际目录组数为该参数与 Cache 组数的较小值。每个目录组按 Cache way 保存有效位和地址 tag。以行地址的低位索引，tag 保存其余全部高位；二者合起来保留完整的 28 位行身份，包含被目录索引压缩的 Cache set 高位。因此不同物理 set 映射到同一目录项时，只会丢失证明，不会误判命中。

默认顶层选择 256 项；独立 Cache 默认关闭目录，保留兼容入口。在 D 16 KiB、512 set、两路配置中，每个 tag 为 21 位，共保存 `256 × 2 × (21 + 1) = 11,264` 位元数据。tag 无需复位，复位只清有效位。

## 更新与失效

成功的 s2 命中和无错误的 refill 建立对应 way 的证明。开始处理 miss 时，先清除被选中 victim way 的证明，其他 way 保留；refill 或写回错误不会建立新证明。不同物理 set 的目录别名可能覆盖或清除证明，随后仍可通过正常 Cache 请求重新建立。

查询并行比较各 way 的有效位与完整 tag。Store 还必须合法、对齐、可接收，并且前序 s0/s1/s2 不存在同组不同地址行的请求。只有实际 valid/ready/irrevocable 握手才能退休；缺失或无法证明的命中等待响应。命中不产生 ECC/权限错误的既有接口语义仍是该保证的前提。

## 接线与验证

`student_top.STORE_DIRECTORY_ENTRIES` 连接 D-Cache；`request_irrevocable_o` 继续经过 MMIO 排除门连接 core/LSQ。接受后由 Cache 原流水线持有已提交写，回滚和 LSQ flush 不取消它，Load 转发、标签化响应以及三周期无阻塞命中契约沿用现有通路。

`make store-directory-unit` 检查目录别名、完整高地址、单项目录、容量截断、1/2/3/4 way、替换与错误、反压、部分字节写，以及已提交写跨回滚/flush。测试包含 512 set 的实际评测几何；每项执行均有 timeout。该目标已加入 `make unit`，启用目录的实际几何也加入严格 lint。

目录缺少证明的真实命中还可通过带完整请求身份的后续确认提前退休；共用返回寄存器和所有权规则见[后续确认设计](late-store-confirmation.md)。
