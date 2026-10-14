# 最高档性能调查复现

基线是 VerilogCPU `033a46d`，FE2/BE2、PRF64、ROB32、恢复4、Store提示16、I1 KiB单路、D16 KiB两路。正式RTL保持不变；参数与返回元数据选择候选只在build下冻结副本中修改。SORA不修改。

```sh
timeout -k 5 3600 python3 -B experiments/tier3_20261014/run.py \
  --out build/tier3-replay/profile \
  --variants baseline hints64 be4 wide4 window lsq16 recovery8 predictor d8 d32
timeout -k 5 180 python3 -B experiments/tier3_20261014/latency.py \
  --sim build/tier3-replay/profile/baseline/sim --out build/tier3-replay/latency
timeout -k 5 180 python3 -B experiments/bottlenecks_20261014/probes.py \
  --sim build/tier3-replay/profile/baseline/sim --out build/tier3-replay/probes
timeout -k 5 420 python3 -B experiments/tier3_20261014/response_mux.py \
  --out build/tier3-replay/response-mux --variants registered-owner
```

每次构建360秒、两个作业；每个性能程序30秒、300万周期上限。依赖链微基准由独立架构解释器产生预期结果；官方程序使用原始镜像、预期结果和动态指令数。`DETAIL`记录退休分支、需求refill地址、请求ID关联的响应延迟；`PROFILE`保留既有分类。

本次原始证据在`build/tier3-20261014`：

- `profile/`：60次参数实验及输入哈希；六项基线周期与上一轮逐项一致。
- `latency/`：18次外存敏感性实验；1/5/20周期均为诊断设置。
- `probes/`：5个通用热Cache微基准。
- `response-mux/`：两处返回元数据mux使用注册的MMIO所有权，六项周期不变。
- `preabc.ys/.json/.log`、`path-audit.json`：旧最终PPA路径回溯。`preabc.ys`取自既有`ppa-v6/mapping/opt/synth.ys`中ABC之前部分，再写出JSON；单次240秒上限。`paths.py`审核保存的状态边界并关联RTL名称。
- `framework-54fc150/`、`framework-302f0cf/`：更新前后课程框架的Git归档。
- `upstream-update.json`、`framework-update.patch`：快进更新记录及完整diff。
- `official-synth/`、`response-mux-ppa/`：框架更新前的两项中止运行，不计入PPA验收。
- `official-updated-baseline/`、`official-updated-mux/`：新版官方默认约束的配对综合。

新版官方综合使用冻结的`framework-302f0cf/scripts/synth.py`，未经流程替换，参数为`--mode opt --clock-period 2.0 --abc-driving-cell INVx1_ASAP7_75t_R --abc-load-ff 5.0`，Yosys/ABC为仓库`.deps/yosys/bin/`固定工具，OpenSTA为`.deps/opensta/bin/sta`，库为`.deps/asap7/lib`。输入分别为旧PPA已经投影为同配置的`build/hum-20261014/ppa-v6/input/filelist.f`及候选的`response-mux-ppa/input/filelist.f`。每次总超时1800秒；生成的`.ys`、`abc.constr`、report与日志作为流程证据。

两次综合均完成。基线为27,066.73 µm² / 293.41 MHz，注册所有权候选为26,929.94 µm² / 302.69 MHz；候选仅变更两处mux，六项周期不变。完整参数与原始路径在`results-summary.json`及build目录；这些为官方模型下的综合估计，未另做布局布线或hold修复。

`summarize.py`目前针对本次保留目录审核并生成摘要，重播到其他目录时需相应修改目录参数。报告区分周期实验、旧定制PPA和新官方PPA，不混用不同版本成绩。
