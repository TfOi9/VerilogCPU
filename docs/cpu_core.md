# 参数化多发射乱序 CPU 核心

`rv32_cpu_core` 将已有前端、重命名、ROB、保留站、执行单元、LSQ 与完成网络闭环。`FE_WIDTH` 和 `BE_WIDTH` 分别支持 1、2、4，共 9 种独立宽度组合。`student_top` 保持单发射默认参数，在核心外实例化分离的 I/D Cache 与 AXI4-Lite 桥接层，并只暴露官方规定的总线端口。

`RECOVERY_WIDTH` 默认4，独立控制 ROB 到 rename、整数/乘除/访存 RS、LSQ 的恢复总线宽度。它不改变发射、完成和退休端口数；单独组件默认值仍兼容 `BE_WIDTH`。恢复顺序和精确异常语义见 [ROB](rob.md)。

## 执行与写回

核心按 `BE_WIDTH` 实例化整数 ALU，因此四发射配置可以同周期执行四条就绪的整数或控制流指令。乘法器、除法器和 LSU 各保留一个。完成源数量为 `BE_WIDTH+3`：低 `BE_WIDTH` 个来源对应整数 ALU，随后依次为乘法器、除法器和 LSQ。完成网络为每个来源保留一个缓冲，每周期最多向 ROB 交付 `BE_WIDTH` 条结果；只有 ROB 接受且目标指令需要写寄存器时，结果才写入物理寄存器并广播唤醒各保留站。

所有整数、乘除法和访存地址候选先经过[统一发射仲裁器](issue.md)，按 ROB head 的环形年龄选择，每周期合计最多发射 `BE_WIDTH` 条，其中访存地址最多一条。Store 数据补送不重复计数。未获授权的指令保留在对应保留站。整数和乘除法执行请求的 valid 与保留站 ready 同时受 grant 控制；访存先授权后发送 LSQ，LSQ ready 不反馈到仲裁选择。

每个整数 ALU 独立传递 ROB tag、结果、控制流方向和实际下一 PC，也独立接受完成网络回压。多个分支同周期完成时，ROB 选择程序顺序中最老的错误预测作为恢复点。多于 `BE_WIDTH` 个来源同时完成时，其余结果留在各来源缓冲中，不允许覆盖或丢失。

核心在各 ALU 的完成端检查控制流目标是否按 4 字节对齐。未对齐时，完成源携带 cause 0 的指令地址未对齐异常，tval 为实际目标，并屏蔽该源的控制流有效位，避免错误目标触发预测器训练或 ROB 重定向。异常经过已有完成网络进入 ROB：若属于错误路径，由较老分支恢复撤销；若成为最老指令，则精确停止且不退休、不提交目的寄存器。

ROB 检测到预测目标不一致后保存正确 PC，并从尾部逆序撤销年轻指令。rollback 总线同时连接 rename、所有保留站和 LSQ；恢复期间暂停 dispatch、issue、completion 和 commit，较老指令及其尚未消费的完成结果继续保留。Fetch 在收到 redirect 时清空取指队列并使旧 I-Cache 响应失效。

## 访存与提交

Load 和 Store 保留站分别计算地址，Store 还独立发送数据。LSQ 负责地址顺序检查、Store-to-Load forwarding 和异常记录。普通请求进入 D-Cache；合法的 `0x80000000` word Store 带 MMIO 标记，由 `student_top` 绕过 D-Cache 送入 AXI bridge 的单 beat 客户端。

Store 只有位于 ROB 头部时才能由 LSQ 发出。LSQ 等待 D-Cache 或 AXI B 响应，将成功状态记录为 `write_done`，随后才拉高对应 commit ready。因此普通 Store 和结束 MMIO Store 的写入都发生在 ROB 头部的提交阶段，成功响应后才能退休。精确异常到达 ROB 头部时核心进入静止状态，不新增非官方顶层端口。

## 顶层接线

`student_top` 实例化核心、参数化 I-Cache、参数化 D-Cache 和共享 AXI bridge。核心到 D 侧的一笔请求只能进入 D-Cache 或 MMIO 路径之一；顶层记录该请求的归属，响应只返回给原请求。Cache miss 使用 128 位行接口，MMIO 使用一个 32 位 AXI 写事务。

`verilog/filelist.f` 以仓库内相对路径列出所有 RTL。`make build` 使用参数构建包装脚本及 CPU 2026 官方 harness 生成默认单发射模拟器；`make build-dual` 使用相同文件列表、FakeRAM 和官方 harness，并将顶层宽度设为 2，产物位于 `build/official-dual`。`make smoke-dual` 与 `make test-dual` 分别执行双发射短程序和官方 correctness 回归，不覆盖单发射构建目录。

核心定向与随机测试使用受控取指响应，检查各宽度的满宽整数 issue、ALU 完成、跨执行类别完成冲突、bundle 内 RAW/WAW、跨 bundle 唤醒、多个分支同周期完成时的最老错误预测恢复，以及错误路径普通/MMIO Store 抑制。

## 独立宽度与测试构建

`make build-configured FE_WIDTH=4 BE_WIDTH=2` 将产物写入 `build/official-4x2`。`smoke-configured` 和 `test-configured` 使用相同参数及隔离目录；`regression-widths` 对全部 9 种组合执行静态检查、组件测试、退休差分及官方功能回归。已有单、双发射入口继续保留。

`student_top` 与核心的默认物理地址、ROB 索引和 tag 位宽随 `PHYS_REGS`、`ROB_ENTRIES` 计算，后续子模块接收同一套位宽。`build-configured`、`smoke-configured`、`test-configured` 支持这两个容量变量；非默认容量的产物增加 `-pPHYS-rROB` 后缀。第 25 项完整容量/宽度检查与代表配置回归见 [parameter_matrix.md](parameter_matrix.md)。

FE 大于 BE 时，dispatch 仅消费最多 BE 条连续前缀，其余指令留在 Fetch Queue；FE 小于 BE 时，本周期最多消费 FE 条，后端仍可从已有队列发射或退休最多 BE 条。lane 0 始终代表输出中的最老项。

测试构建定义 `RV32_TEST_WATCHDOG`，连续 100000 周期无退休时立即失败。该计数器不会因分支恢复被重置，只在复位或真实退休时清零，并通过 `SYNTHESIS` 排除于综合。测试不增加顶层端口。

参数化核心测试使用独立 RV32IM 架构模型生成程序和退休参考，逐条比对 PC、原指令、目的寄存器及结果；同时施加取指和访存延迟，覆盖宽度峰值、依赖、ROB/队列环回、同时分支解析、旧响应及错误路径 Store。7 来源完成竞争另由连接真实 ROB 和 PRF 的集成测试验证。
