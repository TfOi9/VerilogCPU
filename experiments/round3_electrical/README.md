# 第三轮隔离优化实验

正式 RTL 基线 `4fa767cf09cdeebd1ced43973d53490acb6008a5`，前一轮证据来自 `experiments/round2_20261013/`。本轮不改正式 RTL、工具、既有用户文件或 SORA，不推送。

输出在 `build/round3-electrical/`。`baseline`、`lsq-turnover`、`rs-ready-cut` 复用前一轮已验证快照、IPC 和原始官方映射；`combined` 由 RS 副本加上 LSQ 消泡构成，重新跑完整回归和官方综合。四配置是 2×2/P64/R32、1×1/P48/R16、4×1/P96/R32、4×4/P64/R16。

## 复现

从仓库根目录运行。先按上一轮 README 建立和验证 `build/round2-20261013/`；当前快照已存在时按哈希复用，不能覆盖来源不同的证据。下面的 `timeout` 使用本机已有 GNU timeout。

```sh
timeout 120 python3 -B experiments/round3_electrical/combined.py --phase stage
timeout 5400 python3 -B experiments/round3_electrical/combined.py --phase regression
timeout 7200 python3 -B experiments/round3_electrical/combined.py --phase simulation
timeout 5400 python3 -B experiments/round3_electrical/synthesize_combined.py
timeout 7200 python3 -B experiments/round3_electrical/optimize.py
timeout 7200 python3 -B experiments/round3_electrical/close_all.py
timeout 300 python3 -B experiments/round3_electrical/paths.py > build/round3-electrical/paths-driver.log 2>&1
timeout 180 python3 -B experiments/round3_electrical/test_checks.py > build/round3-electrical/checks-unit.log 2>&1
```

对组合版本的四个原映射也运行独立电气审计：

```sh
for config in 2x2-p64-r32 1x1-p48-r16 4x1-p96-r32 4x4-p64-r16; do
  timeout 240 python3 -B experiments/round2_20261013/electrical.py \
    --mapped-dir "build/round3-electrical/combined/synth/$config/opt" \
    --out "build/round3-electrical/combined/synth/$config/electrical"
done
timeout 300 python3 -B experiments/round3_electrical/report.py
```

最后生成结构化 `results-summary.json` 和中文 `docs/round3-electrical-optimization.md`，校验来源、库文件、源码、实际约束命令、逐程序结果与 CEC 日志。缺失、失败或哈希变化直接报错，不把过期输出视为通过。`report.py` 先生成结构化结果，再生成文档；提交前应确认该进程成功结束。

阶段内部也有超时：单元900秒、矩阵3600秒、仿真单项600秒、官方综合2400秒、ABC修复600秒、重建/CEC/电气/hold单项180秒。外层 timeout 覆盖官方 timing helper 内部没有子进程超时的路径。综合、修复和 hold 阶段最多并行两个任务；这属于宿主机调度，不改变 RTL。改动修复算法、输入或工具后应建立新实验输出命名空间，已有缓存会拒绝混用。

## 修复与证明

`repair.py` 保留所有原 DFF、SRAM、tie 和顶层端口，单独导出组合 BLIF。ABC 使用原5个标准单元库，执行缓冲/尺寸调整，再以原组合网络作 CEC。常量作为独立符号输入证明后恢复原常量；任意 FF/SRAM 输出组合都在证明范围内。新网表重建通过固定连接锚点消除 Yosys 位编号变化，检查原固定单元完整字典与顶层端口完全相同，再对全组合边界做第二次 CEC。

ABC 的 INVx1 输入驱动、5 fF 输出负载、fanout=8 和 slew=100 ps 是修复启发式，实际 STA 使用原 SDC 和未修改的 Liberty。重建后用真实 cap/slew 违例修复顶层别名输出的总负载，并重新证明。`hold.py` 在原 SDC 下独立审计全部 hold 违例，按违规组合驱动插入缓冲延迟，重新证明并复查电气。对直接 PI 或原固定单元驱动的残余违例会失败，不擅自改变状态边界。

`test_checks.py` 在真实 CPU 网表副本中分别破坏状态输入、接口名称及可观察的组合逻辑，验证三种检查确实拦截错误。负向副本与失败日志单独保存，不污染任何被比较候选。

`paths.py` 关联隐藏 FF 与公开修复单元，计数关键路径组合弧，保存最大延迟级、负载、扇出和原 FF 来源。原流程已清除的网络名/来源不会被推测为确定事实。

## 证据边界

新组合回归为186条单元 PASS、81配置/381项矩阵检查/207次功能运行、BE=1/2/4的LSQ边界测试、100次官方和24次微基准。前三版本的回归与 IPC 复用上一轮；本轮对其网表实施等价组合优化，未重跑前三版本全部程序。

IPC 使用固定10周期内存延迟、六项官方程序的等权几何平均，不包含微基准。所有计数守恒规则与上一轮相同；组合版本124项周期与LSQ逐项相同。

最终 cap/slew/hold 均无违例，但2 ns目标setup仍未通过。频率是官方最小周期搜索的TT、理想时钟、无互连寄生估计，面积含FakeRAM估计。最终最小hold裕量极小，后续需要正裕量目标、多角及布局/CTS/RC分析；本轮不代表物理签核。没有标准单元门级SDF仿真。

完整原始证据保留在本地被忽略的 `build/` 中；提交只包含复现脚本、中文报告和结构化结果。不要移动或编辑原始目录后继续使用旧汇总。
