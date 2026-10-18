# 文档目录

此目录保存各个 CPU 元件的中文设计文档。

当前默认配置的面积优化及三项指标见 [area-optimization-20261018.md](area-optimization-20261018.md)，PRF 的有效位复位结构见 [prf.md](prf.md)。

每个 RTL 元件完成时，应记录其内部结构、主要逻辑和模块接线。

当前已完成的程序镜像流水线见 [image_pipeline.md](image_pipeline.md)。

RV32IM 指令译码器设计见 [decoder.md](decoder.md)。

RV32I 整数算术逻辑单元设计见 [alu.md](alu.md)。

RV32M 三级 Booth-Wallace 流水乘法器设计见 [multiplier.md](multiplier.md)。

RV32M 朴素迭代除法器设计见 [divider.md](divider.md)。

参数化物理寄存器文件设计见 [prf.md](prf.md)。

RAT、RRAT、物理寄存器空闲表与就绪记分牌设计见 [rename.md](rename.md)。

参数化重排序缓冲区设计见 [rob.md](rob.md)。

参数化整数保留站设计见 [int_rs.md](int_rs.md)。

乘除法保留站设计见 [mdu_rs.md](mdu_rs.md)。

LOAD/STORE 保留站设计见 [memory_rs.md](memory_rs.md)。

访存队列设计见 [lsq.md](lsq.md)。

固定延迟主存模型设计见 [memory.md](memory.md)。

流水线 L1 指令缓存设计见 [icache.md](icache.md)。

流水线 L1 数据缓存设计见 [dcache.md](dcache.md)。

Store 后续命中确认、事务所有权与 RAM/MMIO 共用返回寄存器见 [late-store-confirmation.md](late-store-confirmation.md)，小目录的独立 PPA 与最终验收见 [store-confirm-optimization-20261015.md](store-confirm-optimization-20261015.md)。

I/D Cache 行接口仲裁与 AXI4-Lite 转换设计见 [cache_axi_bridge.md](cache_axi_bridge.md)。

参数化多发射乱序核心与 `student_top` 接线见 [cpu_core.md](cpu_core.md)。

官方 RV32IM 正确性回归配置与结果见 [correctness.md](correctness.md)。

Bimodal 与 BTB 分支预测器设计见 [predictor.md](predictor.md)。

参数化取指流水线设计见 [fetch.md](fetch.md)。

Decode、Rename 与 Dispatch 流水线设计见 [dispatch.md](dispatch.md)。

完成仲裁与物理寄存器写回网络设计见 [writeback.md](writeback.md)。

统一发射仲裁器设计见 [issue.md](issue.md)。

第 24 项的全部宽度组合验收及复现命令见 [widths.md](widths.md)。

第 25 项的物理寄存器、ROB 容量与独立宽度矩阵见 [parameter_matrix.md](parameter_matrix.md)。

第 26 项的官方 ASAP7 综合、FakeRAM 面积与 OpenSTA 时序流程见 [synthesis.md](synthesis.md)。

第 27 项的全部性能测试、单参数敏感度、面积与频率门槛及 Pareto 对比见 [performance.md](performance.md)。

总线流水化的正式实现、协议验证、完整回归及优化前后 IPC/频率/面积对比见 [bus_pipeline_performance.md](bus_pipeline_performance.md)。

Cache 容量、两路相联的三程序轻量对照、SRAM 面积预算及后续 IPC 优化方向见 [cache-pilot-20261014.md](cache-pilot-20261014.md)。

Load 多笔在途、Store 同拍提交与提前取指预测的正式实现及部分验证见 [ipc-optimization-20261014.md](ipc-optimization-20261014.md)。

树形选择器、独立回滚宽度、Store交接实验和完整验证见 [optimization-20261014.md](optimization-20261014.md)，选择器结构见 [ranked_select.md](ranked_select.md)。

此前六程序瓶颈、12 组参数对照、依赖链微基准与七条优化方向见 [bottlenecks-20261014.md](bottlenecks-20261014.md)。

默认性能配置的切换、配置对照和未采用的 Store 提前发射实验见 [default-config-20261017.md](default-config-20261017.md)。

分支误预测当拍 redirect 的结构、IPC 与频率权衡见 [early-redirect-optimization-20261017.md](early-redirect-optimization-20261017.md)。

恢复总线宽度 5/6/7/8 的对照、选定宽度 7 的 IPC/面积/频率见 [recovery-width-7-20261017.md](recovery-width-7-20261017.md)。

256 项 Store 驻留目录在恢复宽度 7 上的 IPC、面积和频率见 [store-directory-256-20261017.md](store-directory-256-20261017.md)。

默认前端宽度 4、后端宽度 2 的对照与 PPA 见 [fe4-be2-20261017.md](fe4-be2-20261017.md)。

缓存并行化后的当前瓶颈、上游综合框架更新和最高档优化方案见 [tier3-performance-investigation-20261014.md](tier3-performance-investigation-20261014.md)。

返回标签选择的结构见 [response-ownership.md](response-ownership.md)，完整正确性与新版官方PPA验收见 [return-tag-validation-20261014.md](return-tag-validation-20261014.md)。

返回标签与Load地址接收捷径的分步验收、官方IPC/面积/频率对照和复现证据见 [load-path-optimization-20261014.md](load-path-optimization-20261014.md)。

较老Store地址已知且不重叠时的Load省拍、独立字节区间测试和最新官方对照见 [load-nonoverlap-optimization-20261014.md](load-nonoverlap-optimization-20261014.md)。

总线返回至整数保留站的状态位定位、四种候选筛选、完整回归和IPC乘频率验收见 [return-path-optimization-20261014.md](return-path-optimization-20261014.md)。
