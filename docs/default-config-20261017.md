# 默认性能配置选择（2026-10-17）

本轮把 `student_top` 的默认参数从单发射、4 KiB 直接映射 D-Cache 切换为已验收的 FE=2、BE=2、PRF64、ROB32、I-Cache 1 KiB 单路、D-Cache 16 KiB 两路、256 项 Store 目录、2 项 MSHR。参数范围不变，所有配置仍可通过顶层参数覆盖。

后续的提前重定向、恢复宽度 7、256 项目录和 FE=4/BE=2 进一步把默认六项 IPC 提升到 0.827603，见 [early-redirect-optimization-20261017.md](early-redirect-optimization-20261017.md)、[recovery-width-7-20261017.md](recovery-width-7-20261017.md)、[store-directory-256-20261017.md](store-directory-256-20261017.md) 和 [fe4-be2-20261017.md](fe4-be2-20261017.md)。

## 测量

固定外部内存延迟 10，六项官方性能程序如下。周期越低越好，IPC 使用官方 `metrics.json` 动态指令数除以总周期。

| 程序 | 周期 | IPC |
| --- | ---: | ---: |
| median | 12,630 | 0.551148 |
| multiply | 19,447 | 1.116985 |
| qsort | 197,268 | 0.709188 |
| rsort | 182,978 | 1.069631 |
| towers | 7,789 | 0.677622 |
| vvadd | 5,956 | 0.759570 |
| **几何平均** | — | **0.788517** |

该配置的官方 ASAP7/FakeRAM/OpenSTA `opt` 估计为 **31,068.27 um²**、**352.50 MHz**，最小周期 2.8369 ns。面积距最高档 36,000 um² 仍有余量，估计频率高于 300 MHz；IPC 距 1.0985 仍需结构性优化。PPA 为理想时钟、无布线寄生的估计值，不是布局布线签核。

## 配置对照

| 配置 | 六项 IPC 几何平均 | 相对选定配置 |
| --- | ---: | ---: |
| FE=2/BE=2，D 16 KiB 2-way | 0.788517 | — |
| FE=2/BE=2，D 32 KiB 2-way | 0.795932 | +0.94% |
| FE=2/BE=2，D 16 KiB 4-way | 0.791906 | +0.43% |
| FE=2/BE=2，I 2 KiB，D 16 KiB 2-way | 0.788889 | +0.05% |
| FE=2/BE=4，D 16 KiB 2-way | 0.820926 | +4.11% |
| FE=4/BE=4，PRF96/ROB64，D 16 KiB 2-way | 0.830726 | +5.35% |

继续扩大 Cache 的收益低于 1%；继续扩宽只有 4% 到 5%，且 4x4 的 vvadd 从 5,774 回退到 6,100 周期。此前同流程的 FE2/BE4 频率约 181 MHz，不满足 300 MHz 门槛。因此本轮只切换默认配置，不默认扩宽或继续扩 Cache。

## 未采用的 Store 提前发射

在隔离副本中试验过“Store 地址/数据就绪后提前装入请求，成为 ROB 头部时同拍发出”。该方案使 median、qsort、rsort、towers 改善，但 vvadd 从 5,956 回退到 6,536 周期，六项几何平均只有 +0.56%。回退来自 Store 请求更早占用单请求端口和 Cache 资源，未解决真实缺失等待。该实验未进入正式 RTL，后续应实现 Store 缓冲、写合并或缺失处理，而不是只提前一拍发出。

## 复现

```sh
python3 tools/build_configured.py --framework ../RISC-V-CPU-2026 \
  --filelist verilog/filelist.f --out build/default-config \
  --fe-width 2 --be-width 2 --phys-regs 64 --rob-entries 32 \
  --icache 1024,1 --dcache 16384,2 --jobs 4
```

原始测量、配置扫和 PPA 证据保存在 `build/perf-check-current/`、`build/store-prep-current/` 和 `build/mshr-20261015/prototype5/ppa/opt/report.json`。
