# 分支重启第一步：取指行缓冲

基线为`abedc8b`，固定FE2/BE2、PRF64、ROB32、恢复4、LSQ8、I1 KiB单路、D16 KiB两路、外存10周期。本轮不改变Bimodal/BTB算法或训练时机。所有候选在冻结副本测量，SORA不修改，不推送远程。

## 命令与冻结

原始证据根目录为`build/branch-restart-20261015/`。`baseline/source`在修改RTL之前保存；`selected/source`保存默认4行缓冲。以下命令使用新输出目录，避免覆盖失败或已完成记录：

```sh
python3 -B experiments/load_path_20261014/measure.py \
  --out build/branch-restart-replay/baseline --phase prepare
timeout -k 5 900 python3 -B experiments/branch_restart_20261015/run.py \
  --out build/branch-restart-replay/screen --variants baseline buffer1 buffer2 buffer4
python3 -B experiments/load_path_20261014/measure.py \
  --out build/branch-restart-replay/selected --phase prepare
```

重播时，第一条`prepare`应从基线Git归档或本轮保存的`baseline/source`传入`--source`，第三条从最终候选源码传入。`run.py`的baseline把新组件参数置0；结果已与原始基线逐程序复现。每次构建360秒、两个作业，每项性能程序30秒/300万周期。观察器记录含推测路径的分支就绪至发射，以及ROB redirect至目标入队、分派和退休的直方图。目标退休使用完整ROB标签；新的redirect会取消尚未完成的旧统计，取消数量单列，不能把不同样本集合当成逐事件配对。

对两个冻结测量目录分别执行`measure.py --phase sim`，对选定候选执行`--phase ppa`。官方25程序每项120秒/3000万周期，构建420秒，PPA2400秒。综合使用未经替换的课程`synth.py`、Yosys0.63、OpenSTA、ASAP7、2.0 ns目标、默认ABC驱动`INVx1_ASAP7_75t_R`与5.0 fF负载。基线PPA复用上一轮正式结果，审核全部RTL逐字节相同、脚本和库哈希，并重新运行25程序复现周期。

## 验证

```sh
python3 -B experiments/branch_restart_20261015/validate.py \
  --out build/branch-restart-20261015/gates
timeout -k 5 1800 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 2 \
  --build-root build/branch-restart-20261015/matrix \
  --report build/branch-restart-20261015/matrix.json
python3 -B experiments/branch_restart_20261015/probes.py \
  --root build/branch-restart-20261015
python3 -B experiments/branch_restart_20261015/report.py \
  --root build/branch-restart-20261015
```

`validate.py`按序运行unit、lint、HUM和返回所有权测试，保存真实退出状态与日志，复制可能被下一轮覆盖的固定目录产物。`make unit`包含27组FE/BE/缓冲容量组合、关闭缓冲的负对照和非法容量检查。两项通用分支微基准由独立架构解释器校验结果和动态指令数，分别在两个官方模拟器上运行。

`report.py`目前审核本轮目录和`screen-v3`，重播到其他目录需要调整对应名称。它要求正式RTL与测量副本一致、完整参数矩阵通过、IPC和IPC乘估计频率均提高、面积不超过36,000 µm²、频率至少300 MHz；最高档是否达到单独报告，不把候选验收等同于最高档通过。

## 保留记录

`profile-baseline`保存最初的时序观察；`screen`保存未锁定I-Cache反压请求的初筛，不能作为最终结果。`screen-v3`使用有锁定的最终结构。初稿整数索引导致Verilator未使用位警告，日志保存在`fetch-baseline.log`；精确宽度修复后以独立日志重跑。各冻结目录、官方命令、源码、仿真器和结果哈希保留在build下，验收输入归档于`qualified-inputs`，版本化摘要为`results-summary.json`。
