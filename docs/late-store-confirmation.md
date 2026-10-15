# Store 后续命中确认与共用返回寄存器

Store 目录在接收请求时提供快速驻留证明。目录缺少证明时，请求仍进入 Cache 的正常流水线；真实 tag 命中进入 s2 的边沿产生一次后续确认，普通 RAM Store 可在最终响应前退休。miss、MMIO、非法地址、已经获得快速证明的请求均不产生该确认。默认顶层使用 128 项目录，独立 Cache 和独立 core 默认关闭后续确认以兼容原有接口。

## 内部结构与接线

`student_top.LATE_STORE_CONFIRM` 控制 Cache 和 core/LSQ 的确认接口；顶层仅在普通 RAM、带 ID 和完整 ROB tag 的返回协议下启用。Cache 注册 `store_confirm_valid_o`、2 位请求 ID 和完整 ROB tag，经顶层直连 core 和 LSQ。确认不占用返回端口，也没有反压；不能接收优化提示的恢复周期可以忽略它，随后仍等待正常响应。

LSQ 用请求 ID 查找尚未响应的 pending 项，核对完整 ROB tag、Store 类型、MMIO 排除、discard 和已有不可失败证明。pending 项保存完整 LSQ tag，提交时再与当前队首的 LSQ tag 和 ROB tag 一起比较；LSQ 有效位、Store 类型与代际检查沿用原提交入口。确认也置位对应活跃 LSQ 项的 `write_done`，因此提交暂时受阻时不会丢失证明。确认路径不经过 Load 写回选择与 RS 唤醒。

确认后 pending 项仍保留到最终响应，标记为 `pending_posted`；最终响应只释放其事务所有权，不再授权 LSQ 位置。重复确认同样排除 `pending_posted`，防止完整 LSQ 代际回绕后授权新指令。ID 只在旧响应被接收后才能复用；同周期接收新请求时，新事务的元数据覆盖旧事务，沿用既有规则。

## 替换、恢复与错误

确认只在 s1 的真实 tag 命中能够推进至 s2 时产生。已有 miss、refill 安装、同 set miss 锁定或流水线反压会阻止该推进。确认把 s2 标记为不可失败；FIFO 流水线在写入前保有该行及 way，年轻请求不能越过它替换其所有权。Cache 的命中写不产生权限或 ECC 错误，这是原提前退休协议已有的前提。

恢复、flush 或 pending discard 不接受新确认；存活但错过确认的请求走正常响应，错误仍归属原指令。已确认并退休的 Store 由 Cache 持有，不受 LSQ 回滚或 flush 取消。miss 的脏写回/refill 错误沿用完整请求身份返回，不能提前退休；MMIO 必须等待实际写响应，错误继续产生精确 Store access fault。仿真断言核对确认与 s2 的身份、活跃 LSQ 所有权以及不可失败 Store 的最终响应。

## 返回控制

MMIO 的响应身份在请求握手时登记，其返回作为 `aux_response_*` 输入 D-Cache 末端现有返回队列。仲裁在返回寄存器之前进行，RAM 返回优先，辅助返回等待空位；身份、有效性、数据和错误一同进入 r/skid 寄存器。顶层直接连接统一的寄存返回至 LSQ，删除原 `lsu_mmio_inflight` 驱动的返回后选择器。

普通 RAM Load 仍使用原 s0/s1/s2 与 r 返回寄存器，保持无阻塞命中三周期契约和快速返回/写回旁路。MMIO 在辅助返回被队列接收后增加一个寄存阶段；实际 MMIO 外部写协议不变。独立 Cache 的 `AUX_RETURNS=0` 关闭辅助入口。

## 验证

`make store-confirm-unit` 包含小目录别名、实际 512 set 几何、1/2/3/4 way、阻塞和非阻塞模式、完整请求身份、替换、脏写回/refill 错误、反压、三周期命中、部分字节写、回滚/flush、重复确认、完整代际回绕以及 MMIO 错误归属。`make response-owner-unit` 在返回寄存器之前注入冲突返回，检查仲裁、身份、反压、同周期出入和复位；协议引擎由其他集成检查与官方程序验证。

实验与性能面积时序验收见 `experiments/store_confirm_20261015/`。所有测试带 timeout；官方 PPA 使用未修改的课程脚本、Yosys 0.63、ASAP7、OpenSTA 和 FakeRAM。估计频率不能代替布局布线后的签核。
