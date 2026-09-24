# 官方正确性回归

## 测试配置

本回归使用官方 `RISC-V-CPU-2026-Testcases` 测试集，版本为
`29f980727f7d99a1842a58f34091c7579ba3fe85`。模拟器通过官方 Verilator
构建脚本生成，外存响应延迟为 10 周期，单项最大周期数为 30000000。

若官方框架中的 `testcases` 子模块已经初始化，可直接运行：

```sh
make test
```

本地测试集位于相邻仓库时，使用：

```sh
make test TESTCASES=../RISC-V-CPU-2026-Testcases
```

可以通过 `Case` 只运行一个测试点：

```sh
make test TESTCASES=../RISC-V-CPU-2026-Testcases \
  Case=correctness_add_to_100
```

`make regression` 汇总覆盖组件单元测试、整机 smoke 和官方正确性回归。

## 回归结果

2026-09-25 在默认单发射配置下，19 个官方正确性测试全部通过：

| 测试点 | 周期数 |
| --- | ---: |
| `correctness_add_to_100` | 1545 |
| `correctness_array_test1` | 1787 |
| `correctness_array_test2` | 1921 |
| `correctness_basicopt1` | 1034451 |
| `correctness_bulgarian` | 648914 |
| `correctness_expr` | 1733 |
| `correctness_gcd` | 1347 |
| `correctness_hanoi` | 12821 |
| `correctness_lvalue2` | 941 |
| `correctness_magic` | 1472382 |
| `correctness_manyarguments` | 948 |
| `correctness_multiarray` | 6030 |
| `correctness_naive` | 831 |
| `correctness_pi` | 20184677 |
| `correctness_qsort` | 3831850 |
| `correctness_queens` | 909984 |
| `correctness_statement_test` | 3870 |
| `correctness_superloop` | 1014315 |
| `correctness_tak` | 3329116 |

官方框架的 1000000 周期默认值会使 `basicopt1`、`magic`、`pi`、
`qsort`、`superloop` 和 `tak` 超时。这些测试在提高周期上限后均返回正确
结果；其中 `pi` 本身包含 3117658 条动态指令，因此单发射核心不可能在
1000000 周期内完成。该现象是周期预算不足，不是错误结果或处理器活锁。
