# 写回与 RS 树化隔离实验

正式 RTL 仍为 `4fa767cf09cdeebd1ced43973d53490acb6008a5`，本轮直接对照上一轮 LSQ+RS 组合快照。本轮不合入正式 RTL、不修改 SORA、不推送，保留已有用户修改。

最终快照和原始结果位于 `build/round4-tree-v3/`。前三次启动产生的 `build/round4-tree-initial/`、`build/round4-tree-width-failure/`、`build/round4-tree/` 保留初始化失败、参数边界修正、严格 lint 警告和证明流程调试记录，不混入最终结果。

## 版本与结构

- `baseline`：上一轮的 LSQ 消泡+RS切断组合。统一快速流程中也重新映射并执行20 ps hold目标；IPC复用经过哈希校验的上一轮程序证据。另保留原流程的四配置20 ps基线以量化流程变化。
- `tree-wb`：仅把写回完成通道打包改成按轮询距离排序、平衡计数树和 one-hot 数据归并树。
- `tree-rs`：仅把INT/MDU RS选择改成按ROB年龄和槽位索引排序的平衡计数树、one-hot归并树。
- `tree-all`：两者叠加。LSQ、容量、队列、cache、提交和 MMIO 策略保持上一轮组合版本。

`rv32_ranked_select.v` 先排除所有已锁定端口占用的槽位，再并行计算每个候选之前的有效候选数，计数使用平衡二叉加法树。每个未锁定端口按其在未锁定端口中的序号选择相应 rank；锁定端口保持原槽位。数据和槽号由 one-hot mask 经平衡OR树归并，不串行传递逐端口winner。年龄相同按槽号较小者优先。比较器数量为O(N²)，因此必须实测面积代价，不能只按逻辑深度决定采用。

端口范围沿用CPU支持的1/2/4。四配置改变FE/BE/PHYS/ROB，RS容量保持正式默认INT=8、MUL/DIV=4；N=16等额外选择器/单元测试提供功能证据，不代表这些容量的PPA已测。

写回源年龄为源索引到轮询起点的循环距离，保留原来“最高置位的起点位优先，全部为0则起点0”的行为。RS年龄为原 `rob_distance`，不改变发射次序、广播捕获顺序和背压锁定语义，不增加流水拍。

`stage.py` 生成隔离RTL、单元测试和Makefile副本，冻结源文件哈希。单源写回的槽号宽度至少为1，年龄表达式显式截断。复现时来源不同直接失败，不能覆盖旧快照。实验定义修改后应使用新的输出命名空间。

## 复现

先按上一轮 README 建立并验证 `build/round2-20261013/` 和 `build/round3-electrical/`。在仓库根目录运行，所有长任务都有外层和子任务超时：

```sh
timeout 120 python3 -B experiments/round4_tree/stage.py
timeout 1800 python3 -B experiments/round4_tree/run.py --phase unit > build/round4-tree-v3/units-driver.log 2>&1
timeout 10800 python3 -B experiments/round4_tree/run.py --phase matrix > build/round4-tree-v3/matrix-driver.log 2>&1
timeout 10800 python3 -B experiments/round4_tree/run.py --phase simulation > build/round4-tree-v3/simulation-driver.log 2>&1
timeout 4800 python3 -B experiments/round4_tree/prove.py > build/round4-tree-v3/proof-driver.log 2>&1
timeout 1800 python3 -B experiments/round4_tree/baseline_reference.py > build/round4-tree-v3/baseline-reference.log 2>&1
timeout 10800 python3 -B experiments/round4_tree/common_synth.py > build/round4-tree-v3/common-synth-driver.log 2>&1
timeout 10800 python3 -B experiments/round4_tree/qualify_common.py > build/round4-tree-v3/common-qualify-driver.log 2>&1
timeout 300 python3 -B experiments/round4_tree/test_selector.py > build/round4-tree-v3/selector-tests.log 2>&1
timeout 180 python3 -B experiments/round4_tree/test_guards.py > build/round4-tree-v3/guards.log 2>&1
timeout 4800 python3 -B experiments/round4_tree/provenance.py --variants baseline tree-wb tree-rs tree-all > build/round4-tree-v3/provenance-driver.log 2>&1
timeout 900 python3 -B experiments/round4_tree/report.py
```

`run.py` 每阶段最多两个并发任务；综合每项2400秒，单元每版本1200秒，矩阵每版本5400秒，仿真单项600秒。矩阵覆盖81个参数组合和9个代表功能配置。源代码按 Verilog 2005 检查；官方 FakeRAM 仍使用其已有SV定义。

`prove.py` 在映射到工艺前展开新旧模块，将每个原状态Q按共同寄存器别名逐位对应，严格检查状态覆盖、类型、时钟和顶层接口，再把所有Q作为相同任意输入、所有原状态D和顶层输出作为输出作组合CEC。它没有把ready、年龄或锁定位假设为常量，也不依赖有限拍仿真证明功能。四配置分别验证写回、INT RS和乘/除两类MDU RS，共16组。CPU级完整回归继续覆盖乘除包装。

## 统一综合流程

原 `run.py --phase synthesis` 和 `qualify.py` 保留原官方流程入口；`baseline_reference.py` 单独复现原映射的四个20 ps基线，不等待树化原流程。最终快照的4×4树化候选触发Yosys `opt_muxtree` 长时间递归搜索，采样位于该pass，保留在 `sample-*.txt` 与 `official-aborted.json`。原流程主动中止，没有将其计为完成。该中止记录是本次诊断证据，干净环境复现报告时需保留本次原始证据目录。

最终PPA使用 `common_synth.py`：调用原框架的参数投影、SRAM准备、dfflibmap、ABC、面积与时序分析，仅将Yosys synth展开为明确命令序列，并把其中opt调用改为opt -fast。该模式跳过opt_muxtree，也改变opt内部reduce/share等循环；完整展开脚本保存在每个候选的synth.ys。显式FSM、算术、share和memory步骤保持，实际Liberty及SDC不变。没有修改框架、正式工具或SORA文件。

基线与三个候选均在四配置按统一流程重新映射，再执行相同电气修复和20 ps hold目标。对比用同流程基线；旧流程数值单列，不能把流程差异算作树化收益。统一流程原始综合在 `common-synth/`，修复结果在 `common-qualified/`。

## 电气与 hold 裕量

沿用上一轮 `repair.py` 的原库组合缓冲/尺寸调整、固定状态检查、每次重建CEC和cap/slew检查。`margin.py` 在实际原SDC下独立查询最坏hold及所有低于0.020 ns的端点；对其组合驱动加延迟缓冲，重新做等价、setup、cap/slew和hold检查，直到最坏裕量至少20 ps且近阈值端点数为0。

所有版本都从hold填充前的电气修复网表开始，使用相同20 ps目标，避免把新树化版本与上一轮仅要求非负hold的结果直接比较。原2 ns时钟目标、接口延迟、负载、时钟不确定度和Liberty限制不变，20 ps只是修复验收目标。若遇到直接PI或固定状态驱动而现有证明边界无法安全修复的情况，工具直接报错。

`test_selector.py` 对独立顺序参考实现运行21组、21000次随机事务，包含非二次幂数量、同龄tie和锁定端口。`test_guards.py` 验证更改时钟、遗漏状态、破坏可观察逻辑、空裕量报告和截断报告均被拒绝。

频率/面积仍是TT、理想时钟、无提取寄生的官方估计，SRAM使用FakeRAM估计；20 ps名义hold裕量不替代多角、CTS、RC及OCV检查。未运行门级SDF仿真。IPC固定内存延迟为10周期，六项官方性能程序取等权几何平均，微基准单独验证。
