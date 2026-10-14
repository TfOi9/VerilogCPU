# 返回至整数保留站的时序优化

基线`07e32b8`。重新fetch后官方框架仍为`302f0cf3cccdaa5de084a2120e0d950c663e4cf5`。固定FE2/BE2、PRF64、ROB32、恢复4、LSQ8、Store提示16、I1 KiB单路、D16 KiB两路、外存10周期；使用原始官方综合脚本、Yosys0.63、OpenSTA3.1.0、ASAP7固定库、2.0 ns目标、默认ABC驱动/负载。

## 冻结和官方测量

```sh
python3 -B experiments/load_path_20261014/measure.py \
  --source build/return-path-20261014/baseline/source \
  --out build/return-replay/baseline --phase prepare
python3 -B experiments/return_path_20261014/candidate.py \
  --source build/return-path-20261014/baseline/source \
  --out build/return-replay/source --variant metadata-wb
python3 -B experiments/load_path_20261014/measure.py \
  --source build/return-replay/source \
  --out build/return-replay/selected --phase prepare
```

对每个冻结目录执行`measure.py --phase sim`及`--phase ppa`。prepare要求新目录；内部timeout分别限定构建420秒、各程序120秒/3000万周期、PPA2400秒，保留所有输入、原始命令和日志。不会覆盖失败或旧结果。模拟器使用官方CPP，未使用定制计数器替换官方结果；PPA未使用FAST_SYNTH、修改网表或hold修复。

四种结构候选：`metadata`提前选择LSQ返回payload；`metadata-wb`再取消写回数据门控；`rs-retain`只保留已发射整数RS的payload并独立捕获唤醒；`metadata-wb-rs`合并三项。最终选择`metadata-wb-v2`冻结版本。四种修正后的候选各跑25官方程序和PPA；全部程序周期相同，按IPC乘官方估计频率筛选。

首稿在wire初始化表达式中使用尚未声明的reg，被Icarus拒绝。改为独立wire声明并在声明完成后assign，重建到`*-v2`独立目录。失败日志保留于`screen/`，原`metadata/`PPA主动中止且标记未完成。最初RS原型与v2仅排版不同，也保留，未用其结果替代最终测量。

## 状态位定位

`preabc.ys`使用原官方脚本至ABC之前的完整前缀，追加write_json作诊断；所有官方PPA文件保持原状。`paths.py`按保留的顺序单元名称、类型、属性和端口宽度，将官方最差路径的两个端点关联到RTL状态位。此方法成功识别原路径`bridge.parallel_adapter.response_locked`至`core.int_rs.entry_lhs_value[5][25]`。

```sh
python3 -B experiments/return_path_20261014/paths.py
python3 -B experiments/return_path_20261014/trace_selected.py \
  --measurement metadata-wb-v2 --phase replay
python3 -B experiments/return_path_20261014/trace_selected.py \
  --measurement metadata-wb-v2 --phase audit
```

诊断重放使用1200秒timeout；它不构成另一套成绩或签核流程。

## 完整资格验证

```sh
timeout -k 5 1800 make unit
timeout -k 5 1800 make lint
timeout -k 5 1200 python3 -B tools/test_hum.py \
  --out build/return-path-20261014/final-hum
timeout -k 5 10800 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 4 \
  --build-root build/return-path-20261014/final-matrix \
  --report build/return-path-20261014/final-matrix.json
python3 -B experiments/return_path_20261014/probes.py --measurement metadata-wb-v2
python3 -B experiments/return_path_20261014/qualify.py --measurement metadata-wb-v2
python3 -B experiments/return_path_20261014/report.py
```

`screen.py`在两个payload候选上运行22项现有LSQ/写回/ROB协议测试。`rs_screen.py`在基线和两个RS候选上各运行九组复用测试、九组1500周期的独立Python模型检查，共54组。最终`make unit`包含新加入的九组RS复用测试；其36,864项检查覆盖无效广播、同拍唤醒发射、槽位复用、反压锁定、回滚和flush。

`qualify.py`固定读取本轮目录，重播时需调整路径。必须保存unit/lint/HUM的执行状态至`final-gates.json`，以及deep JSON至`final-deep.json`，再运行资格审核；不能仅凭部分PASS行填写退出状态。脚本检查全部矩阵、官方日志及产物哈希，要求全部25项周期保持、频率追回此前312.96 MHz、IPC乘频率超过优化前及不重叠Load优化之前，并冻结资格输入与固定目录单元证据。

原有未提交文件保持原状，只在全部资格通过后本地提交。中文设计与接线见`docs/lsq.md`、`docs/writeback.md`，结果见`docs/return-path-optimization-20261014.md`。
