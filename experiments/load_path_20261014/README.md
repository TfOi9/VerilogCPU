# 返回标签和 Load 路径优化

本轮从 `6fb7028` 开始，官方框架重新 fetch 后仍为 `302f0cf3cccdaa5de084a2120e0d950c663e4cf5`。基准固定 FE2/BE2、PRF64、ROB32、恢复宽度4、LSQ8、Store提示16、I1 KiB单路、D16 KiB两路、外存10周期。

`measure.py` 将RTL冻结在build下，投影公开参数和等价空端口连接，然后分别运行官方仿真与未经替换的官方综合脚本。综合直接使用默认ABC约束，Yosys0.63、OpenSTA3.1.0及固定ASAP7库，不调用FAST_SYNTH、网表修复或自定义hold流程。

```sh
python3 -B experiments/load_path_20261014/measure.py \
  --source . --out build/load-path-replay/owner --phase prepare
timeout -k 5 3900 python3 -B experiments/load_path_20261014/measure.py \
  --out build/load-path-replay/owner --phase sim
timeout -k 5 2500 python3 -B experiments/load_path_20261014/measure.py \
  --out build/load-path-replay/owner --phase ppa
```

仿真构建上限420秒，每个官方程序120秒、3,000万周期；综合上限2400秒。官方25项程序全部运行，其中六项性能使用原始动态指令数计算IPC几何平均。prepare必须使用新目录，失败、中止和旧结果不得覆盖。

每一步还执行以下验证，输出目录按步骤分别保存：

```sh
timeout -k 5 1800 make unit
timeout -k 5 1800 make lint
timeout -k 5 1200 python3 -B tools/test_hum.py --out build/load-path-replay/owner-hum
timeout -k 5 10800 python3 -B tools/run_parameter_matrix.py \
  --all-performance --jobs 2 --lint-jobs 2 \
  --build-root build/load-path-replay/owner-matrix \
  --report build/load-path-replay/owner-matrix.json
```

返回所有权的边界注入由`tools/test_response_owner.py`执行；总线、LSQ与流水线错误/反压/恢复场景另由启用断言的原有测试与HUM测试覆盖。边界测试首稿错误地force了与顶层reset同一网络的桥接器reset，导致测试环境失败，已删除该force并改为明确隔离子模块监视器；最初日志保存在`build/load-path-20261014/owner-unit/`，不计作RTL失败或通过证据。

`qualify.py`只审核已经全部完成的门槛，并将RTL、测试及工具源文件复制到独立资格快照，以便后续改动之后仍能审计先前结果。该脚本固定读取本次`build/load-path-20261014`目录，重播到其他目录时需同步修改路径。原始报告、命令、日志、网表和源码哈希全部保留；跟踪的`*-results.json`是可审计摘要。
