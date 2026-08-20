# RAT、RRAT 与物理寄存器分配

## 功能

`rv32_rename_unit` 集中维护乱序后端的寄存器重命名状态，包括推测映射表 RAT、提交映射表 RRAT、物理寄存器空闲表和就绪记分牌。模块按 `BE_WIDTH` 同时处理最多 1、2 或 4 条指令，lane 0 位于所有 packed bus 的最低位。

复位后 x0 到 x31 分别映射到 p0 到 p31，p32 到 p(`PHYS_REGS-1`) 进入空闲表。p0 固定对应 x0，永远就绪且不会被分配或释放。该恒等映射与物理寄存器文件复位为零的行为共同构成初始架构状态。

## 内部结构

RAT 包含 32 个物理寄存器编号，表示当前推测执行路径看到的最新映射。rename 读取 RAT 得到两个源物理寄存器；写 rd 的指令从空闲表取得 `new_phys`，同时将被覆盖的 RAT 项作为 `old_phys` 输出。后续 ROB 必须保存 rd、`new_phys` 和 `old_phys`，供提交与错误路径撤销使用。

RRAT 同样包含 32 个物理寄存器编号，但只表示已经按程序顺序提交的映射。提交 lane 按 oldest 到 youngest 顺序旁路：每条写 rd 的提交先读取当前 RRAT 项作为待释放寄存器，再用 `new_phys` 更新 RRAT。因此同周期连续提交多个相同 rd 时，后一个 lane 会释放前一个 lane 刚提交的物理寄存器。普通提交不会修改 RAT，因为 RAT 可能已经指向更年轻的版本。

空闲表是容量为 `PHYS_REGS-32` 的循环 FIFO。头指针用于 rename 分配，尾指针用于接收 commit 或 rollback 释放的编号，指针通过固定次数的边界减法显式环回，因此支持 48、96 等非二次幂物理寄存器数量且不会综合出除法或取模单元。一次 rename bundle 需要的全部寄存器都可用时才允许 `rename_fire_i`；不进行部分分配。提交释放的寄存器要到下一周期才能参与分配，避免形成从 commit 到 rename ready 的组合路径。

就绪记分牌为每个物理寄存器保存一位 ready。新目的寄存器在分配时被清零，writeback 广播将其置位。组合读路径包含同周期 writeback 旁路，以便和物理寄存器文件的数据旁路保持一致。空闲寄存器的 ready 位没有语义；它在下次分配时一定会重新清零。

## Bundle 内旁路

rename 组合逻辑按 lane 0 到 lane N 的程序顺序更新临时 RAT 和临时 ready 状态。每条 lane 先读取源映射，再处理自己的目的映射。因此：

- 后续 lane 能读取前面 lane 刚产生的 `new_phys`，正确表达 bundle 内 RAW；
- 多条指令写同一个 rd 时，每条指令获得正确的 `old_phys`，最后一条成为 RAT 中的最新映射；
- 指向 bundle 内新目的的源操作数返回 not-ready；
- 无效 lane、不写 rd 的 lane 和写 x0 的 lane 都不消耗空闲寄存器。

`rename_ready_o` 只由周期开始时的 free count、bundle 中有效写 rd 的数量、复位和恢复状态决定。只有 `rename_fire_i && rename_ready_o` 才会在上升沿更新 RAT、空闲表头指针和记分牌。

## 提交与恢复

正常周期最多接受 `BE_WIDTH` 条 oldest 到 youngest 排列的提交。RRAT 是提交旧映射的权威来源，提交端只需提供 valid、writes-rd、rd 和 `new_phys`。模块允许 commit、rename 和 writeback 在同一周期发生，并统一计算空闲表计数变化。

分支恢复由 `recover_i` 选择，rollback lane 必须按 youngest 到 oldest 排列。每个写 rd 的撤销项执行：

1. `RAT[rd]` 恢复为 ROB 保存的 `old_phys`；
2. 被撤销的 `new_phys` 写入空闲表尾部。

同一恢复 bundle 中对相同 rd 的多个撤销按 lane 顺序应用，较老撤销项最后写入，从而还原到错误路径之前的映射。RRAT 和记分牌在恢复中保持不变；重新分配被回收寄存器时，ready 会被清零。恢复周期禁止 rename 和 commit，并抑制 writeback 更新。状态优先级为复位、恢复、正常周期。

这里不能用 `RAT = RRAT` 代替逐项撤销，因为分支解析时可能仍存在位于分支之前、尚未提交但应保留的指令。RRAT 仍负责标识精确的已提交状态，并决定提交时释放哪个物理寄存器。

## 与 SORA 的区别

SORA 的 RAT 将逻辑寄存器映射到 ROB tag，推测结果保存在 ROB/CDB，退休时才写入独立的架构寄存器文件。该架构寄存器文件本身就是已提交状态，所以不需要 RRAT；ROB 项释放后 tag 自动复用，也不需要物理 free list 或物理 ready 表。

SORA 在错误预测分支到达 ROB 头时清空整个推测后端，清空 RAT 后可直接从架构寄存器文件继续。本项目在执行阶段解析分支并只撤销更年轻的指令，同时执行结果会提前写入物理寄存器文件，因此必须分别维护 RAT、RRAT、物理寄存器生命周期和 ready 状态。

## 接线

decode/rename 阶段连接 `rename_valid_i`、rs1、rs2、writes-rd 和 rd，并使用 `rename_ready_o` 参与整 bundle backpressure。源物理编号和 ready 位送往保留站；`new_phys`、`old_phys` 和 rd 随指令写入 ROB。

ROB 提交端连接 commit 接口，ROB 尾部回退端连接 rollback 接口。rollback 的 lane 顺序与普通 commit 相反。完成仲裁网络把最多 `BE_WIDTH` 路写回物理编号连接到 writeback 接口，数据本身同时写入物理寄存器文件。

模块在仿真中检查参数、物理编号范围、p0 释放、空闲计数上下溢、资源不足时 fire、恢复期间正常流量以及同周期重复回收。协议检查不进入综合网表。
