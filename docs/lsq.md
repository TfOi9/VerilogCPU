# Load/Store Queue

`rv32_load_store_queue` 保存未完成的访存指令。默认 8 项，每项记录完整 ROB tag、类型、宽度、无符号标志、地址、store 数据、执行和提交状态。LSQ tag 默认由 3 位槽索引及 2 位 generation 构成；槽位复用时 generation 递增，地址、数据与回滚输入同时核对 ROB tag 和完整 LSQ tag。分配按 dispatch lane 顺序选择空槽，并对整个 bundle 原子接收。

本文的按序响应和等待Store响应描述对应兼容模式。当前顶层启用的标签化返回、驻留Store提前退休和结果旁路，分别见[缓存并行化](cache-parallel-optimization-20261014.md)与[posted Store和返回旁路](posted-stores-and-result-bypass.md)；下面的地址接收捷径同时适用于兼容和标签化通路。

## 访存顺序与转发

LOAD 和 STORE 保留站可以同时提出地址，但 LSQ 每周期只接收一条，优先接收相对 ROB head 更老的指令。store 地址和数据分别到达，两者齐备后报告执行完成。load 必须等待全部更老 store 的地址已知，然后逐字节寻找覆盖目标字节的最近更老 store。全部字节可转发时直接组合并扩展；部分覆盖或数据未就绪时保守等待；无重叠时访问 D-Cache。

命中的 store 字节用 2 位偏移直接选择数据中的四个 8 位切片，避免为每组 load/store/字节生成通用移位器并触发昂贵的 SAT 资源共享分析。`make synth-unit` 从实际 RTL 提取该选择逻辑，用 Yosys SAT 证明它对任意 32 位 store 数据及四种偏移，都等于原来的右移后截取低 8 位。访存顺序、最近 store 选择和响应时序不改变。

普通 RAM 地址范围为 `0x00000000..0x0fffffff`，访问必须按宽度自然对齐。`0x80000000` 是单独的退出 MMIO 地址，只允许 32 位 Store；MMIO Load、SB/SH、其他 RAM 范围外地址以及非对齐访问均生成精确地址异常且不发出存储请求。非对齐异常原因为 load/store 4/6，其他地址错误为 5/7，`tval` 保存原始有效地址。

## Load地址接收捷径

每个LSQ槽根据已注册的busy、类型和相对ROB head的年龄，并行计算`older_store_mask`。收到Load地址时，只查询对应槽位的年龄掩码，避免在保留站选出tag之后再比较年龄。完整ROB/LSQ tag核对、单AGU仲裁和地址合法性检查仍需通过。

`access_mask`将访问宽度和字内偏移解码为四位字节掩码。新Load地址与每项Store并行比较：未知地址、地址异常、MMIO Store或同一字内字节掩码相交，都标记为冲突。`incoming_load_blocked`是较老Store掩码与冲突向量相与后的归约OR。自然对齐且合法的BYTE/HALF/WORD访问不会跨字，因此“字地址不同或字节掩码不相交”足以证明不重叠；非法Load仍由原有地址检查拒绝。

若请求寄存器可接收、没有MMIO隔离、没有优先准备的Store或原有待发Load，且所有较老Store地址已知、合法且与新Load不重叠，那么在接收地址的同一边沿，直接把地址及完整身份装入请求寄存器，并置`started`。Store数据可以尚未就绪；较年轻Store不会阻挡捷径。地址数组和异常状态仍正常更新。这省掉了“写入地址数组后，下一拍扫描再装请求”的一拍；请求寄存器和Cache三周期命中契约保持。

任何较老Store地址未知或存在字节重叠时，仍走原有选择/逐字节转发通路，完整覆盖时转发，部分覆盖或数据未就绪时等待。MMIO和地址异常Store在捷径中保守回退；原有路径的异常与顺序规则沿用。请求反压、在途ID分配、返回字节扩展和精确异常处理沿用现有逻辑。恢复/flush期间不接收新地址，不发出捷径请求；完整标签检查阻止复用槽被陈旧地址污染。

新增测试直接检查省掉的一拍，并覆盖稳定反压、较年轻Store、ROB回绕中的较老Store、恢复同拍取消、LSQ generation和ROB身份不匹配；现有测试继续检查未知Store、部分覆盖、符号扩展、错误响应及在途容量。具体IPC、面积和频率对照见[Load路径优化验收](load-path-optimization-20261014.md)。

不重叠扩展的测试使用独立的地址区间判定，覆盖784组合法宽度、偏移、同字/相邻字/远地址、数据就绪与ROB回绕组合；另检查多个较老Store、未知地址、部分覆盖、同拍AGU仲裁和异常路径。每个组合通过真实分配、地址、请求、响应和完成握手验证。最新验收见[不重叠Store优化](load-nonoverlap-optimization-20261014.md)。

## 请求路由与提交

LSQ 对外使用单通道 ready/valid、按请求顺序返回的协议，允许多笔已握手请求在途。`MAX_INFLIGHT` 默认为 4，须为正的 2 的幂；额外有一项尚未握手的请求寄存器。元数据 FIFO 保存读写/MMIO/discard、完整 ROB/LSQ tag 和原始字节地址；头尾指针及计数支持同拍入队出队。返回时核对 live LSQ 项的两个完整 tag，再读取其宽度和符号信息。请求寄存器握手当拍可以装入下一笔 Load，完成缓冲交接当拍可以接收下一笔响应，命中时支持每拍一笔。

`cache_request_mmio_o=0` 表示普通 RAM 请求，应送往 D-Cache；`cache_request_mmio_o=1` 只与合法退出 Store 同时出现，集成层必须绕过 D-Cache 并送往 AXI4-Lite 写通道。退出请求固定输出地址 `0x80000000`、原始 32 位 store 数据和 `4'hf` byte enable。MMIO 必须等 FIFO 排空后才能发出；MMIO 在途期间禁止发出或准备新的普通请求，因此 `student_top` 的单项 MMIO 响应路由标志仍然成立。

store 首次完成后仍留在 LSQ，真正的写入仍只能在成为 ROB 头部后发生。普通 RAM Store 成功响应握手当拍可旁路 `write_done` 直接允许 lane 0 退休；较高 lane 的普通 Store 只有在全部较老 lane 当拍实际退休且无异常时，才能装入请求寄存器，下一拍发出时它已是新头部。这消除了响应、退休和准备下一请求间的空泡，没有增加“退休后仍可能报错”的 Store buffer。

MMIO 只从 lane 0 准备，保持等待 B 响应并登记 `write_done` 后退休。所有请求在回压期间保持稳定。写错误禁止成功旁路和下一 Store 提前准备；LSQ 补发 cause 7 的异常完成，等待 ROB 保存晚到异常后才允许异常退休。AXI 路由层将 MMIO 的 B 通道状态转换为 `cache_response_valid_i/cache_response_error_i`。

load 请求可在满足顺序约束后乱序发出。读响应按原地址选择字节或半字并执行符号或零扩展，再进入单项完成缓冲。读错误生成 cause 5。普通 store 数据按字内偏移移位并产生相应 byte enable；退出 MMIO Store 始终为完整字写。

## 返回payload与资格分离

开启`LOAD_FALLTHROUGH`时，`response_payload`只由已注册的`source_valid`决定：完成缓冲为空则提前选择在途返回的tag、扩展值和异常字段，有缓冲结果则选择注册payload。`response_bypass`仍检查在途身份、读类型、discard、Cache valid及恢复条件，只有完整资格通过才形成`completion_valid_o`并允许握手或释放Load项。关闭旁路时仍使用原有注册payload。

这使ROB能够与返回资格判断并行准备tag查询，消除组合资格信号再选择tag和值的串行等待。`completion_valid_o=0`时，payload可变化且不保证为零；下游必须以valid和握手决定使用。完整tag校验、反压捕获、错误处理及不重叠Load省拍均保持。正式对照见[返回路径时序优化](return-path-optimization-20261014.md)。

## 恢复与接线

选择性恢复阻止新请求、响应和完成握手，并按完整 tag 删除错误路径项，同时扫描整个在途 FIFO 标记匹配项为 discard。恢复结束后旧响应按序排空，不污染复用槽。全局 flush 清空 LSQ 和未握手请求，但保留已握手 FIFO 的计数与 tag，并将它们全部标记为 discard；即使 generation 复位后发生同 tag 复用，也不会接收旧响应。reset 才会清空在途 FIFO，需与 Cache/存储系统同时施加。系统集成不得用 flush 取消已经交给存储系统的架构 Store。

LSQ 分配端连接 dispatch 和 ROB allocation tag；地址、store 数据端连接两个访存保留站；完成端连接完成仲裁网络；ROB 的提交候选、提交 fire、异常状态和回滚 tag 连接提交与恢复端口。存储路由层依据 `cache_request_mmio_o` 在 D-Cache 与退出 MMIO 之间选择目的地，并把选中目的地的响应返回 LSQ。

定向测试覆盖未知 store 地址、逐字节转发、部分覆盖、不同宽度与符号扩展、回压、tag 复用、恢复、RAM 最后合法字、RAM 上界、合法 MMIO Store、非法 MMIO 宽度和地址，以及 MMIO 成功与错误响应。LSQ 与 ROB 的集成测试继续核对 load 写回、store 顺序提交和晚到异常。

新增测试覆盖四项在途加第五项回压、完成缓冲同拍交接、有序数据/异常关联、多个已发请求回滚、flush 后同 tag 复用、Store 成功当拍退休与下一项准备、错误阻止年轻 Store，以及 MMIO 前后排空。轻量性能与验证结果见 [ipc-optimization-20261014.md](ipc-optimization-20261014.md)。
