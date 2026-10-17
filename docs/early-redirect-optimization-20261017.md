# 分支误预测提前重定向（2026-10-17）

本轮把分支误预测的 fetch redirect 从“下一周期进入 recovery 后发出”改为“检测到误预测的当拍发出”。ROB 仍在下一周期进入注册 recovery 并完成年轻项回滚，但取指可以提前一拍启动正确路径；同一误预测不再重复发送 redirect。

## 实现

ROB 原来把 `mispredict_next_pc_reg` 在进入 recovery 时复制到 `recovery_redirect_pc_reg`，下一周期由 `recover_redirect_valid_o` 输出。现在 `recover_redirect_valid_o` 直接使用组合的 `mispredict_found_reg`，`recover_redirect_pc_o` 选择 `mispredict_next_pc_reg`；删除 `recovery_redirect_pending_reg` 和 `recovery_redirect_pc_reg`。误预测完成所在周期的正常提交/完成/分配语义不变，recovery 状态机与回滚总线不变。

仿真校验比较严格：同周期多个误预测仍按相对 ROB head 的距离选择最老分支；`recover_busy_o` 在下一周期才拉高；提前 redirect 与 recovery 回滚不会重复清除年轻项。ROB 单元测试已改为在误预测当拍检查 redirect、在 recovery 第一拍检查 redirect 已撤销。

## 性能

固定 FE=2、BE=2、PRF64、ROB32、I-Cache 1 KiB 单路、D-Cache 16 KiB 两路、外存延迟 10。周期越低越好。

| 程序 | 原周期 | 新周期 | IPC 变化 |
| --- | ---: | ---: | ---: |
| median | 12,630 | 12,240 | +3.1% |
| multiply | 19,447 | 18,763 | +3.5% |
| qsort | 197,268 | 192,341 | +2.5% |
| rsort | 182,978 | 182,928 | +0.03% |
| towers | 7,789 | 7,727 | +0.8% |
| vvadd | 5,956 | 5,919 | +0.6% |
| **几何平均** | **0.788517** | **0.802700** | **+1.80%** |

六项均有改善，没有程序回退。

## 面积与频率

同一官方 ASAP7/FakeRAM/OpenSTA `opt` 流程、2 ns 目标：

| 指标 | 原实现 | 提前 redirect | 变化 |
| --- | ---: | ---: | ---: |
| 总面积 (um²) | 31,068.27 | 31,092.03 | +0.08% |
| SRAM (um²) | 6,723.84 | 6,723.84 | 0 |
| 估计频率 (MHz) | 352.50 | 344.20 | -2.35% |
| 最小周期 (ns) | 2.8369 | 2.9053 | +2.41% |

提前 redirect 新增了一条从完成/ROB 误预测选择到 fetch redirect 的组合路径，估计频率下降约 2.35%。IPC 提升 1.80%，IPC×估计频率约下降 0.59%；但最高档的硬门槛是 IPC≥1.0985、面积≤36,000 um²、频率≥300 MHz，本实现仍满足面积和频率条件，而 IPC 是当前唯一未达标的约束，因此保留该优化。频率为理想时钟、无互连寄生的估计值，不是布局布线签核。

## 验证与复现

- 官方 25 项程序在 FE=2/BE=2、D-Cache 16 KiB 两路配置全部通过，六项性能周期与插桩分析一致。
- `make unit`、`make lint` 通过。
- ROB 单元测试 16x1、32x2、64x4 全部通过；新增/修改检查覆盖误预测当拍 redirect、recovery 首拍不重复 redirect、最老误预测选择和回滚边界。
- 官方 PPA 输入、日志和报告保存在 `build/ppa-early-redirect/`，性能构建在 `build/early-redirect/`。

本轮未修改 SORA，未推送远程。
