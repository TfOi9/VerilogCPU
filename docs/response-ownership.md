# 返回标签与响应所有权

`student_top` 使用寄存器 `lsu_mmio_inflight` 记录当前 LSU 响应通路的所有权。RAM 与 MMIO 请求的隔离、MMIO 必须等待前序 RAM 排空的约束仍由 LSQ 保证。

## 结构和接线

请求握手时，`core_d_request_mmio` 写入所有权寄存器；响应握手时清零。MMIO 请求握手同时保存请求的 ROB tag 和在途 ID。响应侧的 valid、data、error、ROB tag 和 ID 全部使用同一个已注册的所有权选择：

- 所有权为 RAM：选择 D-Cache 的响应，ready 仅送给 D-Cache。
- 所有权为 MMIO：选择桥接器的 MMIO 响应及保存的身份，数据为零，ready 仅送给 MMIO。

此次仅把 ROB tag 和 ID 两处选择条件从组合 `mmio_response_valid` 改为 `lsu_mmio_inflight`，没有增加流水级，也没有改变请求/响应握手或异常语义。返回身份不再依赖桥接器响应仲裁的组合 valid。

反压时所有权和 MMIO 身份保持不变。路由状态机支持响应完成同拍的新RAM请求；当前LSQ仍按自己的排空与请求准备规则决定实际握手时刻。MMIO请求必须满足LSQ排空约束，不能与尚未结束的普通请求重叠。

## 验证方法

`tools/test_response_owner.py` 在实际顶层的内部接口注入请求和响应，检查 ROB16/32/64 下全部标签值、ID 复用、请求反压、响应反压、错误标志、交接和复位，共7,168项检查。该边界测试使用 `SYNTHESIS` 关闭被隔离子模块的仿真监视器；它不代替总线和流水线集成验证。

完整验证另外使用启用监视器的全部单元测试、HUM/标签随机测试、官方25程序和81参数配置矩阵。矩阵包含九组代表配置的退休差分及全部官方程序；PPA 使用上游 `302f0cf` 的原始综合脚本及默认 ABC 约束。每次运行的源码、日志和报告记录在 `build/load-path-20261014/`，最终实测数量与结果见本轮性能报告。
