# Store 驻留证明目录实验

基线为 `3f0636c`。先冻结 FE2/BE4、PRF64、ROB32、I 1 KiB 单路、D 16 KiB 两路、外存 10 周期的配置，用原版官方流程检查 PPA。结果为 30,180.33 µm² / 181.21 MHz，频率未达到 300 MHz，因此目录采用 FE2/BE2。

实现按 set 索引、按实际 Cache way 保存完整地址身份的目录，保留零项参数对应的原 FIFO 提示。试验了 32/64/128 项及 set 高位折叠；小目录仍有覆盖损失，折叠没有稳定改善均值。256 项普通索引候选的六程序 IPC 为 0.731136（+1.40%），选定配置官方 PPA 为 33,593.58 µm² / 318.61 MHz。面积增加 23.16%，IPC×估计频率提高 4.50%；最高档 IPC 1.0985 仍未达到。

## 复现入口

所有准备阶段使用新的输出目录，后续阶段读取该目录的冻结源和 SHA256 守卫。正式源码、官方脚本、工具、程序镜像与参考结果由测量和验收脚本核对。BE4 原始 PPA 使用实现目录前的精确源码，下面命令读取其冻结副本。

```sh
python3 -B experiments/store_directory_20261015/measure.py --phase prepare --source build/store-directory-20261015/be4-baseline/source --be-width 4 --directory 0 --out build/store-directory-be4
python3 -B experiments/store_directory_20261015/measure.py --phase ppa --out build/store-directory-be4
python3 -B experiments/store_directory_20261015/measure.py --phase sim --out build/store-directory-be4

python3 -B experiments/store_directory_20261015/screen.py --out build/store-directory-screen --variants be2-dir0 be2-dir32 be2-dir64 be2-dir128 be2-dir256
python3 -B tools/test_store_directory.py --out build/store-directory-unit
python3 -B experiments/store_directory_20261015/measure.py --phase prepare --directory 256 --out build/store-directory-selected
python3 -B experiments/store_directory_20261015/measure.py --phase sim --out build/store-directory-selected
python3 -B experiments/store_directory_20261015/measure.py --phase ppa --out build/store-directory-selected
python3 -B experiments/store_directory_20261015/validate.py --out build/store-directory-gates
timeout -k 5 3600 python3 -B tools/run_parameter_matrix.py --build-root build/store-directory-matrix --report build/store-directory-matrix.json --all-performance --testcases ../RISC-V-CPU-2026-Testcases --jobs 2 --lint-jobs 2
```

`measure.py` 直接调用未修改的课程 `scripts/synth.py`，使用 Yosys 0.63、OpenSTA、ASAP7、2 ns 时钟及默认 ABC 驱动单元/5 fF 负载。每次综合 timeout 为 2,400 秒，构建 420 秒，每程序 120 秒；局部测试每次 30 秒。SRAM 由 FakeRAM 模型计面积，时序为理想时钟、无布线寄生的官方估计，不代表物理签核。

## 本次原始记录

`build/store-directory-20261015/` 保存本次冻结目录与输出：

- `be4-baseline/`：实现目录前的 BE4 源、25 项程序与官方 PPA。
- `screen/`、`screen-256/`：普通索引的容量筛选；`screen-hash-v2/` 为未采用的折叠试验。
- `selected/`、`profile-final/`：精确选定源码的正式仿真、PPA 和观测统计。
- `gates/`、`matrix.json`：单元、lint、71 组目录检查、28 组 HUM、7,168 次响应所有权检查与完整参数矩阵。
- `probes/`：32/64/96 条驻留行的通用 Store 环；独立解释器生成结果与动态指令数，正式/观测仿真周期必须相同。
- `negative-control/`：旧实现对新驻留保留要求的预期拒绝。
- `unit-v1/`：覆盖计数错误的测试初稿；`unit-hash/`：折叠试验的 refill 位选错误，保存失败源码。`screen-hash/` 在定向失败后中止，未用于验收。

`report.py --root build/store-directory-20261015` 在所有门槛完成后生成 `results-summary.json`，核对源码、镜像、结果、周期、几何平均、综合库与产物、完整矩阵和各检查的实际状态。零目录模式逐项复现六项基线周期。容量筛选只代表周期敏感度；各小容量及折叠候选没有独立 PPA，不能与选定方案的频率拼接。
