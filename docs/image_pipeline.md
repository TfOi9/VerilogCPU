# 裸机程序镜像生成流水线

本项目的裸机程序从 C 源文件生成可供 CPU 和 SORA 参考仿真器加载的稀疏镜像。流水线固定保留中间目标文件，便于检查编译器生成的指令和链接地址：

```text
C --gcc -c--> program.o
startup.S --gcc -c--> startup.o
runtime.c --gcc -c--> runtime.o
program.o + startup.o + runtime.o + libgcc --link.ld--> program.elf
program.elf --objcopy--> program.bin
program.elf --ELF load segment conversion--> program.image
```

## 地址和接线

CPU 的取指地址从 `0x00000000` 开始。链接脚本将 `0x00000000..0x00000fff` 分配给启动 ROM，将 `0x00001000..0x000fffff` 分配给代码、只读数据、可写数据和 BSS；栈顶为 `0x00100000`，栈向低地址增长。所有可加载段的 `p_memsz` 都必须落在 `[0, 1 MiB)` 内，不能只检查文件中实际存在的字节。

启动代码完成栈指针设置和 BSS 清零，然后调用 `main`。`main` 返回后，`a0` 保留返回值。紧随其后的 `li a0, 255` 编码为 `0x0ff00513`，是 CPU/SORA 约定的 HALT 指令；仿真器在执行该指令前读取 `a0[7:0]` 作为返回值，因此启动代码不会覆盖用户结果。

最小运行时提供 `memset`、`memcpy` 和 `memmove`。编译器在 RV32I 下遇到 ISA 不包含的算术操作时，可从同一 multilib 的 `libgcc` 引入软件辅助函数；RV32IM 则允许 GCC 直接生成 M 扩展指令。

## 镜像格式

`.bin` 是 `objcopy -O binary` 生成的连续原始文件，适合 ROM 初始化工具。`.image` 是稀疏文本格式：

```text
@00000000
13 05 F0 0F ...
@00001000
...
```

`@` 后是八位十六进制字节地址，后续是按小端内存顺序排列的两位十六进制字节。没有列出的地址保持为零，适合 SORA 的 1 MiB byte memory。`.json` 保存入口地址、HALT 地址、段的文件/内存大小、ISA 和地址范围，便于测试脚本及后续 RTL testbench 复用。

## 使用和验证

```sh
python3 tools/make_image.py tests/programs/accumulate.c --arch rv32i
python3 tools/make_image.py tests/programs/accumulate.c --arch rv32im
make image-test
```

`make image-test` 会分别构建 RV32I 和 RV32IM，并检查 `.o`、ELF 入口 `0x0`、HALT 字节、镜像格式、1 MiB 上界；若本机存在已构建的 SORA interpreter/simulator，还会在 30 秒超时内验证 `0..100` 累加结果的低八位为 `186`。
