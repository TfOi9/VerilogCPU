# 综合目录

`make synth MODE=diagnose` 和 `make synth MODE=opt` 通过
`tools/run_synthesis.py` 调用官方框架的 `make synth`，不复制或修改官方脚本。
`make synth-matrix` 对第 25 项的 9 个代表配置分别运行两种模式。

依赖由 `make synth-setup` 安装到 `.deps/`，版本与校验和见
`third_party/synthesis-lock.json`。综合产物在 `build/synth/`，机器可读汇总
和 Markdown 表格在 `reports/`，均不提交生成文件。

流程、接线、报告含义与复现命令见 [../docs/synthesis.md](../docs/synthesis.md)。
