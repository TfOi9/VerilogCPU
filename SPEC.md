# Verilog CPU Spec

## 基本要求

我们需要实现一个乱序执行、能够参数化的多发射 RISC-V CPU。

### 参数化范围

- 前端宽度/后端宽度：1/2/4 生成不同的发射宽度的 CPU。
- 物理寄存器大小：不同的物理寄存器大小产生重命名空间。
- ROB 大小。

### 指令集

RV32IM；可以参照 https://msyksphinz-self.github.io/riscv-isadoc/html/rvi.html。

### 要跑的程序

- 0 到 100 的累加
- 一个向量乘法：https://github.com/ucb-bar/riscv-benchmarks/blob/4d46f673ae42a321e35f5b40b2f5c8f498bc1d9d/multiply/multiply_main.c#L35-L40
- 一个向量加法：https://github.com/ucb-bar/riscv-benchmarks/blob/master/vvadd/vvadd_main.c#L26-L31
- SORA 仓库中 data/testcases/ 下的所有 .c

### 内存与程序结束

- 外部 RAM 为 256 MiB 小端内存，地址范围为 `0x00000000` 到 `0x0fffffff`。
- 程序通过向 `0x80000000` 执行对齐的 32 位 Store 结束，写数据为返回值，byte enable 必须为 `4'hf`。
- 结束 Store 只有到达 ROB 头部后才能对外发出，并且必须等待写响应。
- `0x0ff00513` 是标准的 `ADDI a0, x0, 255`，不得作为特殊终止指令。

以上程序都需要：

- 从 .c 代码用 riscv-gnu-toolchain-gcc 编译出 .o
- 工具链可用 https://github.com/riscv-collab/riscv-gnu-toolchain，也可以先检查本机是否已有安装
- 抽出对应函数的 binaries
- 投入 CPU 并运行

## 详细要求

你可以参照 SORA 仓库的仿真器设计；确保你一边对照 SORA 仿真器的实现一边理解下述要求。

- 需要实现标准的五级流水线乱序执行（Tomasulo 算法）
- 需要实现内存设计（高访存延迟，初始可以采用 50 周期固定延迟）
- 需要实现分离的 L1 I/D Cache（3 周期命中延迟，流水线化）
- 需要实现简单的分支预测器（简单 Bimodal + BTB，暂不考虑 TAGE）
- 还要实现乘法器与除法器，其中，乘法器需要做成 3 周期流水线（Booth 编码与部分和生成 + Wallace Tree 与 CSA 加法器 + 最终加法）；除法器暂时先只实现朴素除法器
- 其他部件设计可以参照 SORA，包括 ALU, RS, ROB, LSQ 等等

请注意，SORA 的部分设计有小问题，详见[文档](SORA.md)

## 验收

- 跑完上述所有程序的仿真（85 分基本分）
- 用 YoSys + ASAP7 工艺库综合面积
- 一个顺序单发射的CPU核心面积在 1000 um2 量级（Reference: UCB Sodor）
- 理论上单发射乱序的面积应该在 1500-2000 um2 量级，要按照 performance / area 来算每次面积增加对于性能的影响，面积翻倍性能至少要多出来 1.3×，每达到一个多给 5 分；
- 上述验收应该一步步顺序地做，即先跑通所有的仿真，后续再做面积优化等等。
