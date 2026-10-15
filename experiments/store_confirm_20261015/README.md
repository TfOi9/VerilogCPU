# 小目录、后续确认与返回控制链优化

本轮限定为下一轮最小工作包：补齐 64/128 项目录的独立官方 PPA，验证真实 tag 命中后的身份化不可失败确认，将 RAM/MMIO 选择前移至返回寄存器之前。基线为 `85867e4` 的 256 项目录、FE2/BE2、PRF64/ROB32、I 1 KiB 单路、D 16 KiB 两路、外存 10 周期。

设计见 [后续确认与返回寄存器](../../docs/late-store-confirmation.md)。原始日志、完整冻结 RTL、命令、官方脚本校验、仿真与综合产物在 `build/store-confirm-20261015/`。最终源码由 `final128/` 冻结，不能用早期候选的时序代替。

## 复现

```sh
# Baseline source is an immutable snapshot of commit 85867e4.
python3 -B experiments/store_directory_20261015/measure.py --phase prepare --source build/store-confirm-20261015/baseline64/source --directory 64 --out build/store-confirm-repro/baseline64
python3 -B experiments/store_directory_20261015/measure.py --phase sim --out build/store-confirm-repro/baseline64
python3 -B experiments/store_directory_20261015/measure.py --phase ppa --out build/store-confirm-repro/baseline64
# Repeat with directory 128 in a different output directory.

python3 -B experiments/store_confirm_20261015/measure.py --phase prepare --directory 128 --out build/store-confirm-repro/final128
python3 -B experiments/store_confirm_20261015/measure.py --phase sim --out build/store-confirm-repro/final128
python3 -B experiments/store_confirm_20261015/measure.py --phase ppa --out build/store-confirm-repro/final128
python3 -B experiments/store_confirm_20261015/screen.py --source build/store-confirm-repro/final128/source --out build/store-confirm-repro/control --variants dir128-late0
python3 -B experiments/store_confirm_20261015/screen.py --out build/store-confirm-repro/screen --variants dir64-late0 dir64-late1 dir128-late0 dir128-late1 dir256-late1
python3 -B experiments/store_directory_20261015/validate.py --out build/store-confirm-repro/gates
timeout -k 5 3600 python3 -B tools/run_parameter_matrix.py --build-root build/store-confirm-repro/matrix --report build/store-confirm-repro/matrix.json --all-performance --testcases ../RISC-V-CPU-2026-Testcases --jobs 2 --lint-jobs 2
```

`measure.py` 直接调用未修改的官方 `scripts/synth.py`，固定 Yosys 0.63、OpenSTA、ASAP7、FakeRAM、2 ns 时钟、默认 ABC INVx1 驱动和 5 fF 负载。每次综合限时 2,400 秒，构建 420 秒，每官方程序 120 秒。单元用例每项 30 秒。RTL 用 Verilog 2005 解析与严格 lint，testbench 使用已有的 SystemVerilog 仿真便利语法。

## 数据与验收边界

- `baseline64/`、`baseline128/`：旧实现小目录的 25 项官方程序、六项 IPC 和独立 PPA。
- `final128/`、`profile-final/`、`profile-control/`：最终源码的官方 25 项与观测六项；对应周期必须一致；`profile-control/` 为最终同一源码关闭后续确认的六项对照。
- `screen-v2/`：同一冻结源码下不同目录容量、确认开关的六项机制对照；未逐个综合的变体只有 IPC，不拼接频率。
- `gates-final/`、`matrix-final.json`：最终源码的 unit/lint、HUM、返回所有权、64 组后续确认检查、81 组参数矩阵及代表配置逐退休差分/官方程序。
- `probes-final/`：32/96/160 条驻留行的通用 Store 环，独立 RV32 解释器核对结果与动态指令数，正式与观测仿真周期一致。
- `return-latency/`：仅将原 HUM testbench 的 Cache 参数设为 `AUX_RETURNS=1` 的冻结副本，1/2 way 各四个种子，辅助输入空闲，核对三周期命中、反压及错误，共 3,428 次响应；原 testbench 不改动。
- `path-trace/`：使用官方综合前缀的独立 pre-ABC 诊断重放，关联最长路径状态位，校验原 PPA 产物未变。
- `negative-control/`：禁用后续证明和删除重复确认保护的两份故意破坏副本，分别应被集成检查和完整代际回绕检查拒绝。

`candidate64/`、`candidate128/`、`selected128-v2/`、`gates-v2/`、`matrix/` 是早期候选或检查记录，不参与最终验收。早期 300 秒 lint timeout、布尔参数的显式位宽警告和源码变化导致的旧验证拒绝均保留。汇总初稿把矩阵功能报告中的聚合 RTL SHA 当作逐文件字典，已按生成器的原算法重算并校验，初稿与失败日志保存在 `report-schema-v1.*`。旧矩阵在发现位宽警告后中止；`matrix-interrupted.json` 保存原因及仅本轮被停止的进程。`probes/` 保存初稿：160 行超过参考解释器 20,000 条指令上限，且需要第二基址以保持 Store 的 12 位偏移合法；修正后的通用程序降低循环次数并显式使用第二基址，没有修改解释器上限或硬件。

`trace.py --ppa build/store-confirm-20261015/final128/ppa/opt --out build/store-confirm-repro/path-trace` 可单独重放最终路径。

`report.py --root build/store-confirm-20261015` 只在最终门槛完成后生成机器可读汇总。面积与频率为理想时钟、无布线寄生的官方模型估计；不能称为布局布线签核。本轮不扩宽 BE、不实现多 MSHR、恢复接收或 BP 扩表，后续顺序仍按时序、真实 miss 与恢复代价推进。
