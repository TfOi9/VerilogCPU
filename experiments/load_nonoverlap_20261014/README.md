# 较老Store不重叠时的Load省拍

本轮从`f50d34e`开始。官方仓库重新fetch后仍为`302f0cf3cccdaa5de084a2120e0d950c663e4cf5`。优化前后都重新运行官方25程序与原始综合脚本，保持FE2/BE2、PRF64、ROB32、恢复4、LSQ8、Store提示16、I1 KiB单路、D16 KiB两路、外存10周期。

沿用上一轮`measure.py`冻结源文件、投影公开参数和等价空端口连接。PPA使用Yosys0.63、OpenSTA3.1.0、固定ASAP7库、2.0 ns目标及官方默认ABC驱动和负载。原始日志、输入、命令、网表、报告与哈希保存于`build/load-nonoverlap-20261014/`。

```sh
python3 -B experiments/load_path_20261014/measure.py \
  --source build/load-nonoverlap-20261014/baseline/source \
  --out build/nonoverlap-replay/baseline --phase prepare
python3 -B experiments/load_path_20261014/measure.py \
  --source build/load-nonoverlap-20261014/candidate/source \
  --out build/nonoverlap-replay/candidate --phase prepare
```

对每个冻结目录执行`measure.py --phase sim`和`--phase ppa`。脚本内部限定仿真构建420秒、每个程序120秒/3000万周期、综合2400秒，均使用`timeout -k 5`。prepare只接受新目录，失败和旧证据不得覆盖。

完整资格验证在当前正式RTL上执行：

```sh
python3 -B experiments/load_nonoverlap_20261014/targeted.py
timeout -k 5 1800 make unit
timeout -k 5 1800 make lint
timeout -k 5 1200 python3 -B tools/test_hum.py \
  --out build/load-nonoverlap-20261014/candidate-hum
timeout -k 5 10800 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 4 \
  --build-root build/load-nonoverlap-20261014/candidate-matrix \
  --report build/load-nonoverlap-20261014/candidate-matrix.json
python3 -B experiments/load_nonoverlap_20261014/probes.py
python3 -B experiments/load_nonoverlap_20261014/qualify.py
```

`targeted.py`在18种宽度/ROB/posted-result配置上运行完整LSQ测试，并要求优化前RTL在三个宽度下拒绝新增省拍断言。每个配置的784组合法地址组合由独立区间模型判定重叠，不读取DUT内部冲突信号。旧路径的预期拒绝保留，不能算作CPU功能失败。

最初`targeted-final`审核器因Verilog测试消息的256位长度将首字母截掉而未匹配预期拒绝；原始日志保留。审核器改为匹配完整关键后缀，重新运行到独立`targeted-qualified`目录。该问题没有修改RTL，也没有把原失败当作通过证据。

资格脚本固定使用本轮目录；重播时需调整目录并保留执行状态及日志。所有RTL与测试在回归开始后冻结。中文结构与接线见`docs/lsq.md`，最终结果见`docs/load-nonoverlap-optimization-20261014.md`。
