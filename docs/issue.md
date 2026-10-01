# 统一发射仲裁器

`rv32_issue_arbiter` 限制所有执行类别每周期合计最多发射 `BE_WIDTH` 条指令。`BE_WIDTH` 支持 1、2、4，与前端宽度独立。

## 内部结构与逻辑

仲裁器为组合逻辑，不保存指令。输入包含 `BE_WIDTH+4` 个候选的 valid、可接收状态及完整 ROB tag；按 ROB 索引相对于 head 的环形距离选择最老候选，最多产生 `BE_WIDTH` 个 grant。同年龄时按来源编号选择。tag 的 generation 仍由 ROB 和各队列验证，年龄比较仅使用索引。

Load 与 Store 地址共用一个发射名额，每周期最多选择其中一个。Store 数据补送不表示第二次发射，Cache 访问、重试及退休也不计入发射数。复位、恢复或精确错误停止时，所有 grant 为零。

## 接线

来源编号 0 至 `BE_WIDTH-1` 对应整数 ALU，随后依次为 MUL、DIV、Load 地址及 Store 地址。整数和乘除法候选只有执行单元 ready 时参与选择；未获授权的候选由保留站保持，生产端 ready 和执行单元 valid 同时被屏蔽，避免只启动执行或只移除队列项。

乘除法保留站包装层通过 `issue_valid_o`、`issue_ready_o`、`issue_rob_tag_o` 暴露候选，并接受 `issue_grant_i`。候选 ready 表示执行单元可接收，实际握手还必须具有 grant。

访存候选先按有效地址参与仲裁，授权后才把 valid 送到 LSQ。LSQ 的 ready 仅回传给获授权的地址端，不参与仲裁反馈，避免 valid/ready 组合环。若 LSQ 未接受，地址仍留在保留站，本周期最多浪费一个授权名额，不会重复发射。

整数与乘除法保留站把候选选择、payload 与握手移除逻辑放在不同组合块，确保候选输出不依赖仲裁后的 ready。

## 验证

`make issue-lint issue-unit` 检查全部后端宽度，独立 Python 模型按年龄排序验证候选 mask、回压、ROB 环回、访存互斥与暂停。核心仿真逐周期统计真实握手，检查合计发射数不超过 `BE_WIDTH`，恢复期间为零。
