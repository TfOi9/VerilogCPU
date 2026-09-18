# 文档目录

此目录保存各个 CPU 元件的中文设计文档。

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

Bimodal 与 BTB 分支预测器设计见 [predictor.md](predictor.md)。

参数化取指流水线设计见 [fetch.md](fetch.md)。

Decode、Rename 与 Dispatch 流水线设计见 [dispatch.md](dispatch.md)。

完成仲裁与物理寄存器写回网络设计见 [writeback.md](writeback.md)。
