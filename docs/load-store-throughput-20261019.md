# Load 依赖交接与 Store 连续推进

## 检查点与目标

基于 main `88362c8bafbe5c645a77757dcfa64e9e57d82510`，工作分支为 `codex/load-store-throughput-20261019`。本地保存，不推送远程，不操作 deepseek 分支。

本轮目标为六项 IPC 几何平均大于 0.88、估计 Fmax 大于 350 MHz、面积不超过 31,000 µm²。当前检查点的前两项达标，面积尚未达标；后续单独进行面积优化。

| 配置 | main | 本检查点测量 |
| --- | ---: | ---: |
| FE / BE / PRF / ROB / LSQ | 4 / 2 / 56 / 32 / 8 | 4 / 4 / 56 / 32 / 8 |
| D-Cache / I-Cache | 16 KiB 双路 / 1 KiB 单路 | 相同 |
| Store directory / hints / MSHR | 64 / 8 / 2 | 相同 |
| IPC 几何平均 | 0.8223194830 | 0.9054190403 |
| 面积（µm²） | 30330.608361 | 34177.147767 |
| 估计 Fmax（MHz） | 347.118644 | 362.991847 |

六项周期数：median 10662、multiply 18068、qsort 162799、rsort 151750、towers 6260、vvadd 6023。25 项官方程序全部正确结束。采用官方 Yosys 0.63 / ABC / OpenSTA 3.1.0 / ASAP7 RVT TT / FakeRAM 流程，opt、2 ns 目标、INVx1 驱动、5 fF 负载、理想时钟、无布局寄生；Fmax 属于该流程估计值。

## 内部结构与接线

- LSQ 保留请求寄存器，增加普通 Load 的直接交接。仅当完整 ROB/LSQ 身份有效、所有旧 Store 地址已知且无重叠、无提交 Store 屏障、地址合法、非 MMIO 且有空闲 request ID 时，地址输入可直接连接 D-Cache 请求。反压时捕获请求，后续保持稳定；分配 ID 同时考虑本周期归还信用。
- Store 数据按物理字节对齐，共享 Store 年龄关系；每字节选择最近的旧 Store。未知旧地址阻塞，缺失数据和部分覆盖不产生错误转发。选中 Load 后再组合转发值，避免每个 LSQ 槽重复数据选择器。
- Store 准备只预装最旧、合法、非 MMIO 的候选。正式发出仍校验完整 ROB/LSQ 身份与提交授权。普通 Store 可以使用前缀全部真实退休的后续提交槽；MMIO 仍严格限制在队首。多发射快速模式将 irrevocable 接受证明寄存，切断请求到退休的组合路径。
- Store 响应归还和下一个独立完成可以同周期推进。普通 Store 地址/数据最后到齐即可生成执行完成；异常仍走原有精确异常路径。回滚、迟到响应、request ID、完整 ROB 标签和 LSQ generation 的归属检查保留。
- D-Cache 每路拆成四个 SRAM bank；读 tag 与 Store 写 data 地址独立，不同 bank 可以并行。两 MSHR 的返回阶段允许前级推进，但保持 S2、refill、replay 的互斥和 SRAM 读取条件。命中仍经过 s0/s1/s2/响应寄存器，维持三周期契约，没有命中旁路。
- Memory RS 就绪操作数只在未就绪到就绪时捕获。Issue arbiter 先在两个内存候选中选旧者，再并行计算年龄名次，保持最多一个内存发射、原有年龄和索引优先级。

## 验证边界和复现

精确测量快照与工具/输入 SHA256 保存在 `experiments/load_store_throughput_20261019/checkpoint-snapshot.json`，三份结果 JSON 同目录保存。完整冻结源、投影源、映射网表、STA 与仿真日志保留于 `/private/tmp/verilogcpu-throughput-20261019/wide16k-p56-run`。

测量快照后仅修复 Verilog-2005 声明顺序、显式位宽和 arbiter lint 标注/命名；检查点 RTL 尚需最终同源六项 IPC/PPA 复核，不将这些文字修复后的提交冒充为已完整重测的快照。

已通过：25 项官方程序、六项性能、同快照 PPA；LSQ 32 组定向配置（BE 1/2/4、LSQ 8/16、ROB 16/32/64、快速/兼容、带标签/顺序返回）；Issue BE1/2 的六组 SAT 等价和 BE4 的三组 ABC CEC 等价。较早双 bank 版本通过 64 组 Store 确认/缓存契约测试；四 bank 最终版本仍需重跑完整协议门禁。

待完成：最终同源完整 unit/lint、HUM/deep/response-owner、参数矩阵和三项性能验收。面积超标 3177.15 µm²；本提交是可恢复的吞吐检查点，尚非最终验收。

复现冻结和测量：`python3 -B experiments/load_store_throughput_20261019/measure.py --phase prepare --source . --out <fresh-absolute-directory> --fe 4 --be 4 --phys 56 --rob 32 --directory 64 --hints 8`，随后同一输出目录依次运行 `--phase screen`、`--phase suite`、`--phase ppa`。各子命令均内置 timeout，外层分别建议 900/1200/2100 秒。
