# 完成仲裁与写回网络

## 功能与接口

`rv32_completion_writeback_network` 连接执行单元响应、ROB completion 端口、物理寄存器文件、rename 就绪记分牌和全部保留站的广播端口。模块每周期最多向 ROB 交付 `BE_WIDTH` 条结果，并且只广播 ROB 接受的 live 指令结果。

默认 `SOURCE_COUNT` 为 `BE_WIDTH + 2`。来源 0 到 `BE_WIDTH-1` 对应整数 ALU，来源 `BE_WIDTH` 对应乘法器，来源 `BE_WIDTH+1` 对应除法器。端口采用通用压平总线，后续 LSQ 可以通过增加 `SOURCE_COUNT` 并追加来源接入，无需修改仲裁逻辑。每个来源携带 ROB tag、结果值、控制流信息和异常信息；不支持某类信息的执行单元把对应字段接零。

## 来源缓冲与握手

每个来源配置一个独立的单项弹性缓冲。空缓冲可以接收结果；缓冲结果正在与 ROB 握手时，也可以在同一上升沿接收该来源的下一项结果。这样，整数 ALU 和流水乘法器在无冲突时仍可保持逐周期吞吐。未获仲裁或 ROB 回压时，缓冲保持全部 payload，不覆盖或丢失结果。

ROB completion ready 当前采用全开或全关的 bundle 语义。网络在仿真中检查所有 ready lane 一致。发生回压时，网络停止接收新的来源结果，使已经显示的 completion lane 保持稳定。同步 reset 和全局 `flush_i` 清空全部缓冲；`recover_i` 只屏蔽来源与 ROB 握手并保留已有结果。恢复结束后，ROB 使用完整 generation tag 接受 live 结果并排空 stale 结果。

## 轮询仲裁

仲裁器保存 one-hot 轮询起点，从该来源开始循环扫描所有缓冲，每周期选择最多 `BE_WIDTH` 个有效项。输出 lane 按扫描顺序形成连续有效前缀。只有 `completion_valid_o && completion_ready_i` 才会移除缓冲项，轮询起点更新为最后一个实际交付来源的下一项。

轮询依据 ROB ready 而不是 accept 更新。因而已经回滚、generation 不匹配、重复或已经完成的结果虽然不会再次修改 ROB，仍能从完成网络排空，不会永久占用来源缓冲。所有来源具有相同仲裁地位，持续的整数完成流量不会饿死乘除法结果。环回使用常量比较和减法，不使用行为级除法或取模。

## ROB 查询与写回

执行单元只传递 ROB tag 和结果，不携带目的物理寄存器。ROB 对每个被接受的 completion lane 输出 `completion_writes_rd_o` 和 `completion_phys_o`；未接受 lane 的两个字段固定为零。这样无需扩大 ALU、乘除法器或保留站中的在途 payload。

物理写回使能满足以下全部条件：completion 与 ROB 完成握手、ROB accept、指令写 rd、没有完成异常且目的物理寄存器不为 p0。写回物理编号和值同时连接 PRF 写端口、rename writeback 端口以及整数、乘法、除法保留站的广播端口。控制流、store、异常完成和 stale tag 可以更新或排空 ROB，但不会修改 PRF 或唤醒依赖项。

仿真协议检查覆盖非法参数、非统一 ROB ready、无握手 accept、越界物理寄存器、重复物理写回和损坏的 one-hot 轮询状态。单元测试使用独立 Python 模型穷举 1/2/4 路后端的来源 mask 与轮询起点，并额外覆盖回压、连续补入、公平性、恢复、flush、异常和 stale/重复 tag。集成测试连接真实 ROB 与 PRF，检查同周期旁路和上升沿写入。
