# Verilog CPU

参数化、多发射、乱序执行的 RV32IM CPU，使用 Verilog 2005。核心按序退休，支持精确异常、Bimodal/BTB 分支预测、三级流水乘法器、迭代除法器、分离的流水 L1 Cache 和 AXI4-Lite 外存。

## OJ 构建与运行

Linux 环境需要 Python 3.10+、GNU Make、支持 C++17 的 G++、binutils 和 Verilator 5.020 或兼容版本。

```sh
make
./code < testcase.in
```

默认构建生成仓库根目录 `code`。运行时从标准输入读取官方 `CPU2026-OJ 1` 协议，只向标准输出打印返回值；周期统计写到标准错误。运行不依赖相邻仓库、测试数据文件或构建目录。

`third_party/cpu2026` 保存固定版本的官方构建、仿真与综合脚本，未修改上游脚本。来源与文件哈希见其中的 `upstream-manifest.json`。RTL 文件列表为 `verilog/filelist.f`，顶层为 `student_top`。

## 设计与验证

默认配置、100 分门槛、同源性能/面积/时序结果、Linux 验收和参数敏感度见 [最终报告](docs/tier3-optimization-20261019.md)。各元件结构和接线见 [文档目录](docs/README.md)。

开发回归：

```sh
make unit lint hum-unit
python3 -B tools/run_parameter_matrix.py --all-performance --jobs 2 --lint-jobs 2 \
  --build-root build/final-matrix --report reports/final-matrix.json
```

开发测试使用相邻的官方 `RISC-V-CPU-2026` 与 `RISC-V-CPU-2026-Testcases` 仓库；源码提交包的默认 OJ 构建不需要它们。
