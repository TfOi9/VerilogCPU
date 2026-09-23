# 裸机程序镜像生成流水线

本项目将 C 源文件构建为官方 CPU 框架可加载的稀疏字节镜像，并保留目标文件、ELF、反汇编和链接映射，便于检查生成指令与地址：

```text
C --gcc -c--> program.o
startup.S --gcc -c--> startup.o
runtime.c --gcc -c--> runtime.o
program.o + startup.o + runtime.o + libgcc --link.ld--> program.elf
program.elf --objcopy--> program.bin
program.elf --ELF load segment conversion--> program.image
```

## 地址布局与结束协议

CPU 从 `0x00000000` 取指。链接脚本把 `0x00000000..0x00000fff` 分配给启动代码，把 `0x00001000..0x0fffffff` 分配给代码、只读数据、可写数据、BSS 和栈；栈顶为 `0x10000000`，栈向低地址增长。镜像生成器同时检查每个可加载段的 `p_memsz`，保证完整段位于 256 MiB RAM 内。

启动代码设置栈指针、清零 BSS，然后调用 `main`。返回值保留在 `a0`，启动代码随后把 `0x80000000` 装入 `t0`，执行一次 `sw a0, 0(t0)`，再进入兜底死循环。该 Store 由 CPU 在 ROB 头部发出，并以 `WSTRB=4'hf` 完成官方 MMIO 退出协议。`0x0ff00513` 只表示普通 ADDI，不再承担终止功能。

最小运行时提供 `memset`、`memcpy` 和 `memmove`。RV32I 构建可从相同 multilib 的 `libgcc` 引入软件算术辅助函数；RV32IM 构建允许编译器直接生成 M 扩展指令。

## 镜像与 manifest

`.bin` 是 `objcopy -O binary` 生成的连续原始文件。`.image` 使用稀疏文本格式：

```text
@00000000
B7 02 00 80 23 A0 A2 00 ...
@00001000
...
```

`@` 后为八位十六进制字节地址，后续字节按小端内存顺序连续写入；未列出地址由外部内存模型初始化为零。`.json` 保存入口地址、256 MiB 内存大小、各段的文件和内存大小、ISA 以及输出文件名，不包含旧终止指令或地址字段。

## 验证

```sh
python3 tools/make_image.py tests/programs/accumulate.c --arch rv32i
python3 tools/make_image.py tests/programs/accumulate.c --arch rv32im
make image-test
```

`make image-test` 分别构建 RV32I 和 RV32IM，检查 ELF 入口、MMIO 结束指令序列、稀疏镜像内容、BSS 段、256 MiB 地址上界和 manifest 字段。主镜像面向官方框架，不再尝试在采用 1 MiB 内存和旧终止哨兵语义的 SORA 模拟器中直接运行。
