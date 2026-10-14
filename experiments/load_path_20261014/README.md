# 返回标签和 Load 路径优化

本轮从 `6fb7028` 开始，官方框架重新 fetch 后仍为 `302f0cf3cccdaa5de084a2120e0d950c663e4cf5`。基准固定 FE2/BE2、PRF64、ROB32、恢复宽度4、LSQ8、Store提示16、I1 KiB单路、D16 KiB两路、外存10周期。

`measure.py` 将RTL冻结在build下，投影公开参数和等价空端口连接，然后分别运行官方仿真与未经替换的官方综合脚本。综合直接使用默认ABC约束，Yosys0.63、OpenSTA3.1.0及固定ASAP7库，不调用FAST_SYNTH、网表修复或自定义hold流程。

```sh
python3 -B experiments/load_path_20261014/measure.py \
  --source build/load-path-20261014/owner/source \
  --out build/load-path-replay/owner --phase prepare
timeout -k 5 3900 python3 -B experiments/load_path_20261014/measure.py \
  --out build/load-path-replay/owner --phase sim
timeout -k 5 2500 python3 -B experiments/load_path_20261014/measure.py \
  --out build/load-path-replay/owner --phase ppa
```

仿真构建上限420秒，每个官方程序120秒、3,000万周期；综合上限2400秒。官方25项程序全部运行，其中六项性能使用原始动态指令数计算IPC几何平均。prepare必须使用新目录，失败、中止和旧结果不得覆盖。

每一步还执行以下验证，输出目录按步骤分别保存。make与矩阵命令检查当前工作树：第一步应在`2814880`对应源码上运行，第二步使用最终Load版本。上面的测量命令则明确使用第一步的冻结副本。

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

## Load候选与最终测量

`candidate.py`只从第一步冻结副本生成新的隔离RTL目录。`--stores older`在地址到达后比较较老Store，`any`在任何Store存在时阻断捷径，`precomputed`按槽位预计算较老Store约束。本轮选择`precomputed`；正式RTL与其测量快照逐字节一致。

```sh
python3 -B experiments/load_path_20261014/candidate.py \
  --source build/load-path-20261014/owner/source \
  --out build/load-path-replay/load-source --stores precomputed
timeout -k 5 600 python3 -B experiments/deep_20261014/run.py \
  --source build/load-path-replay/load-source \
  --out build/load-path-replay/load-screen --variants i1-d16
python3 -B experiments/load_path_20261014/measure.py \
  --source build/load-path-replay/load-source \
  --out build/load-path-replay/load --phase prepare
timeout -k 5 3900 python3 -B experiments/load_path_20261014/measure.py \
  --out build/load-path-replay/load --phase sim
timeout -k 5 2500 python3 -B experiments/load_path_20261014/measure.py \
  --out build/load-path-replay/load --phase ppa
```

第二步矩阵实际使用`--lint-jobs 4`，其余配置和门槛与第一步相同。两步各重新运行五个通用微基准；第一步使用已核对源码和二进制哈希的缓存profile模拟器，第二步使用选定Load副本的profile模拟器。`load-address-unit-results.json`保留旧路径在省拍断言处的三项预期失败和新实现的三项通过。

最终执行`qualify.py --stage load --measurement load-precomputed`以及`compare.py`，核对全部资格记录、持久化快照、日志和官方/计数器仿真一致性，生成中文验收报告与`results-summary.json`。前一步所有权边界测试的摘要改为引用独立归档路径，避免后续重复测试覆盖其证据。
