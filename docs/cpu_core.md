# 单/双发射乱序 CPU 核心

`rv32_cpu_core` 将已有前端、重命名、ROB、保留站、执行单元、LSQ 与完成网络闭环。当前支持 `FE_WIDTH=BE_WIDTH=1` 和 `FE_WIDTH=BE_WIDTH=2`；混合宽度与宽度 4 留待后续阶段。`student_top` 保持单发射默认参数，在核心外实例化分离的 I/D Cache 与 AXI4-Lite 桥接层，并只暴露官方规定的总线端口。

## 执行与写回

核心按 `BE_WIDTH` 实例化整数 ALU，因此双发射配置可以同周期执行两条就绪的整数或控制流指令。乘法器、除法器和 LSU 各保留一个。完成源数量为 `BE_WIDTH+3`：低 `BE_WIDTH` 个来源对应整数 ALU，随后依次为乘法器、除法器和 LSQ。完成网络为每个来源保留一个缓冲，每周期最多向 ROB 交付 `BE_WIDTH` 条结果；只有 ROB 接受且目标指令需要写寄存器时，结果才写入物理寄存器并广播唤醒各保留站。

每个整数 ALU 独立传递 ROB tag、结果、控制流方向和实际下一 PC，也独立接受完成网络回压。多个分支同周期完成时，ROB 选择程序顺序中最老的错误预测作为恢复点。多于 `BE_WIDTH` 个来源同时完成时，其余结果留在各来源缓冲中，不允许覆盖或丢失。

ROB 检测到预测目标不一致后保存正确 PC，并从尾部逆序撤销年轻指令。rollback 总线同时连接 rename、所有保留站和 LSQ；恢复期间暂停 dispatch、issue、completion 和 commit，较老指令及其尚未消费的完成结果继续保留。Fetch 在收到 redirect 时清空取指队列并使旧 I-Cache 响应失效。

## 访存与提交

Load 和 Store 保留站分别计算地址，Store 还独立发送数据。LSQ 负责地址顺序检查、Store-to-Load forwarding 和异常记录。普通请求进入 D-Cache；合法的 `0x80000000` word Store 带 MMIO 标记，由 `student_top` 绕过 D-Cache 送入 AXI bridge 的单 beat 客户端。

Store 只有位于 ROB 头部时才能由 LSQ 发出。LSQ 等待 D-Cache 或 AXI B 响应，将成功状态记录为 `write_done`，随后才拉高对应 commit ready。因此普通 Store 和结束 MMIO Store 都不会在退休前产生外部可见写入。精确异常到达 ROB 头部时核心进入静止状态，不新增非官方顶层端口。

## 顶层接线

`student_top` 实例化核心、参数化 I-Cache、参数化 D-Cache 和共享 AXI bridge。核心到 D 侧的一笔请求只能进入 D-Cache 或 MMIO 路径之一；顶层记录该请求的归属，响应只返回给原请求。Cache miss 使用 128 位行接口，MMIO 使用一个 32 位 AXI 写事务。

`verilog/filelist.f` 以仓库内相对路径列出所有 RTL。`make build` 使用 CPU 2026 官方脚本生成默认单发射模拟器；`make build-dual` 使用相同文件列表、FakeRAM 和官方 harness，并将顶层宽度设为 2，产物位于 `build/official-dual`。`make smoke-dual` 与 `make test-dual` 分别执行双发射短程序和官方 correctness 回归，不覆盖单发射构建目录。

双发射核心定向测试使用受控取指响应，检查同周期双整数 issue、双 ALU 完成、ALU/乘除法/LSQ 同周期完成冲突、bundle 内 RAW/WAW、跨 bundle 唤醒、两个分支同周期完成时的最老错误预测恢复，以及错误路径 MMIO Store 抑制。
