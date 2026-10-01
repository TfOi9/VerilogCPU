# 第 24 项宽度验收

2026-10-01 验证 `FE_WIDTH` 与 `BE_WIDTH` 独立配置为 1、2、4，固定 `PHYS_REGS=64`、`ROB_ENTRIES=32`，其余队列与 Cache 使用默认参数。发射上限按所有执行类别的真实握手合计计算。

## 功能结果

官方测试集版本为 `29f980727f7d99a1842a58f34091c7579ba3fe85`，外存延迟为 10 周期，每例上限为 30000000 周期、1800 秒墙钟时间，测试构建启用 100000 周期无退休 watchdog。全部 207 项功能测试通过：19 个 correctness、2 个向量程序和 2 个 smoke，分别在 9 种组合下运行。

| FE | BE | correctness | 向量程序 | smoke | pi 周期 | multiply 周期 | vvadd 周期 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 19/19 | 2/2 | 2/2 | 20184678 | 64074 | 29721 |
| 1 | 2 | 19/19 | 2/2 | 2/2 | 20176294 | 63959 | 29721 |
| 1 | 4 | 19/19 | 2/2 | 2/2 | 20170708 | 63948 | 29721 |
| 2 | 1 | 19/19 | 2/2 | 2/2 | 20184651 | 58202 | 29700 |
| 2 | 2 | 19/19 | 2/2 | 2/2 | 20176266 | 57912 | 29697 |
| 2 | 4 | 19/19 | 2/2 | 2/2 | 20170679 | 57901 | 29696 |
| 4 | 1 | 19/19 | 2/2 | 2/2 | 20196559 | 57655 | 34178 |
| 4 | 2 | 19/19 | 2/2 | 2/2 | 20190963 | 57353 | 29691 |
| 4 | 4 | 19/19 | 2/2 | 2/2 | 20188280 | 57584 | 30418 |

向量程序为 `perf_multiply` 和 `perf_vvadd`，此处仅验证功能，不计算性能评分。逐例周期、预期值、状态和日志位置见生成文件 `reports/width-regression.json`；每种配置的构建及程序日志位于 `build/official-FExBE/`。报告记录 RTL 内容 SHA-256，便于核对产物版本。

## 组件与核心验证

- 统一发射仲裁器在宽度 1/2/4 下分别通过 4256/4512/6048 个独立模型向量，覆盖候选与 ready mask、年龄环回、跨类别竞争、访存互斥及暂停。
- 9 种宽度配置通过核心 Icarus Verilog 2005、Verilator Verilog 2005 和 Yosys 检查，Yosys 检查禁止 latch。
- 核心在 seed `0x2401`、`0x2402`、`0x2403` 下完成 27 组逐条退休差分。每组分别比对 917、923、921 条退休记录，覆盖四 lane RAW/WAW、x0、访存宽度、乘除法、混合宽度、队列环回和最老错误预测恢复。
- 四路配置观察到同周期四条整数发射、四路写回和四条退休；全部组合均观察到回滚后的访存响应丢弃及乘除法 stale tag 排空。
- 7 来源完成网络通过 56766 项检查；连接真实 ROB、PRF 的集成测试通过 48 项检查，包括同时接收 7 个来源并最终完成全部写回、退休。
- 乘除法保留站在关闭 grant 的 40 个周期内保持队列项和 tag，执行单元不提前启动；之后正常授权并验证结果。
- 无退休 watchdog 故障注入阻断全部取指，确认在 100000 周期时失败。完整现有组件单元测试通过。

## 复现

```sh
make lint
make unit
make regression-widths TESTCASES=../RISC-V-CPU-2026-Testcases
make smoke-configured FE_WIDTH=4 BE_WIDTH=2
make test-configured FE_WIDTH=4 BE_WIDTH=4 \
  TESTCASES=../RISC-V-CPU-2026-Testcases
```

单个退休差分失败时，日志包含配置、seed、周期和首个错误 PC/结果。以下命令生成相同刺激并保存 VCD：

```sh
python3 tools/generate_core_vectors.py --out build/core-vectors/0x2401 --seed 0x2401
timeout 30 build/core_tb_4x4/core_tb \
  +PROGRAM=build/core-vectors/0x2401.words \
  +TRACE=build/core-vectors/0x2401.trace \
  +EXPECTED=4095 +SEED=9217 +WAVE=build/core-4x4-0x2401.vcd
```

`make core-unit` 先生成刺激及仿真器。所有生成文件均由 `.gitignore` 排除。物理寄存器/ROB 容量矩阵、ASAP7 面积频率与正式性能评分留在后续阶段。
