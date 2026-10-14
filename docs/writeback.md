# 完成仲裁与写回网络

## 功能与接口

`rv32_completion_writeback_network` 连接执行单元响应、ROB completion 端口、物理寄存器文件、rename 就绪记分牌和全部保留站的广播端口。模块每周期最多向 ROB 交付 `BE_WIDTH` 条结果，并且只广播 ROB 接受的 live 指令结果。

默认 `SOURCE_COUNT` 为 `BE_WIDTH + 2`，适用于整数 ALU、乘法器和除法器。整机核心还接入 LSQ，因此显式配置为 `BE_WIDTH + 3`：来源 0 到 `BE_WIDTH-1` 对应整数 ALU，之后依次为乘法器、除法器和 LSQ。端口采用通用压平总线，每个来源携带 ROB tag、结果值、控制流信息和异常信息；不支持某类信息的执行单元把对应字段接零。

## 来源缓冲与握手

每个来源配置一个独立的单项弹性缓冲。空缓冲可以接收结果；缓冲结果正在与 ROB 握手时，也可以在同一上升沿接收该来源的下一项结果。这样，整数 ALU 和流水乘法器在无冲突时仍可保持逐周期吞吐。未获仲裁或 ROB 回压时，缓冲保持全部 payload，不覆盖或丢失结果。

ROB completion ready 当前采用全开或全关的 bundle 语义。网络在仿真中检查所有 ready lane 一致。发生回压时，网络停止接收新的来源结果，使已经显示的 completion lane 保持稳定。同步 reset 和全局 `flush_i` 清空全部缓冲；`recover_i` 只屏蔽来源与 ROB 握手并保留已有结果。恢复结束后，ROB 使用完整 generation tag 接受 live 结果并排空 stale 结果。

## 轮询仲裁

仲裁器保存 one-hot 轮询起点，将每个来源的循环距离送入 [ranked selector](ranked_select.md)，通过并行名次比较和平衡归并树每周期选择最多 `BE_WIDTH` 个有效项。输出 lane 按原循环顺序形成连续有效前缀。只有 `completion_valid_o && completion_ready_i` 才会移除缓冲项，轮询起点更新为最后一个实际交付来源的下一项。

轮询依据 ROB ready 而不是 accept 更新。因而已经回滚、generation 不匹配、重复或已经完成的结果虽然不会再次修改 ROB，仍能从完成网络排空，不会永久占用来源缓冲。所有来源具有相同仲裁地位，持续的整数完成流量不会饿死乘除法结果。环回使用常量比较和减法，不使用行为级除法或取模。

## ROB 查询与写回

执行单元只传递 ROB tag 和结果，不携带目的物理寄存器。ROB 对每个被接受的 completion lane 输出 `completion_writes_rd_o` 和 `completion_phys_o`；未接受 lane 的两个字段固定为零。这样无需扩大 ALU、乘除法器或保留站中的在途 payload。

当前核心启用`SOURCE_AUTH`：各源的完整ROB tag先查询活跃性、generation和物理目的号，授权与数据共同参与仲裁。缓冲源查询其缓冲tag，空源查询执行单元tag，避免跨回滚缓存授权。兼容模式仍使用仲裁后ROB的completion查询。结构见[结果旁路](posted-stores-and-result-bypass.md)。

物理写回使能满足以下全部条件：completion 与 ROB 完成握手、ROB accept、指令写 rd、没有完成异常且目的物理寄存器不为 p0。写回物理编号和值同时连接 PRF 写端口、rename writeback 端口以及全部保留站的广播端口。不写rd的控制流指令、store、异常完成和stale tag可以更新或排空ROB，但不会修改PRF或唤醒依赖项。

目的物理号和值现在直接连接已选payload，独立于`writeback_valid_o`计算；SOURCE_AUTH模式取`selected_phys`，兼容模式取`completion_phys_i`。有效性仍保留原有握手、live授权、重复tag、异常和p0过滤，开启SOURCE_AUTH时由断言核对与ROB接受决定一致。PRF、rename和所有RS继续以`writeback_valid_o`决定写入或捕获，valid为零时不承诺数据字段为零。这样物理号比较可与写回资格并行，减少从返回valid到消费者唤醒的串行门控；没有增加流水级。

新增`make int-rs-reuse-unit`覆盖BE1/2/4与ROB16/32/64的无效广播、同拍唤醒发射、槽位复用、不同物理号、反压锁定、恢复及flush。完整项目回归与新版官方IPC、面积、频率对照见[返回路径优化验收](return-path-optimization-20261014.md)。

仿真协议检查覆盖非法参数、非统一 ROB ready、无握手 accept、越界物理寄存器、重复物理写回和损坏的 one-hot 轮询状态。单元测试使用独立 Python 模型穷举 1/2/4 路后端的来源 mask 与轮询起点，并额外覆盖回压、连续补入、公平性、恢复、flush、异常和 stale/重复 tag。集成测试连接真实 ROB 与 PRF，检查同周期旁路和上升沿写入。
