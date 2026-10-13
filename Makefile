SHELL := /bin/bash

.DEFAULT_GOAL := doctor

.PHONY: build-configured smoke-configured test-configured regression-widths issue-lint issue-unit doctor lint unit build build-dual test test-dual core-lint core-unit memory-lint memory-unit main-memory-lint main-memory-unit icache-lint icache-unit dcache-lint dcache-unit cache-bridge-lint cache-bridge-unit predictor-lint predictor-unit fetch-lint fetch-unit dispatch-lint dispatch-unit smoke smoke-dual regression matrix matrix-lint matrix-functional matrix-unit perf perf-unit synth synth-matrix synth-unit synth-setup report image image-test

PYTHON ?= $(shell command -v /opt/homebrew/bin/python3 2>/dev/null || command -v python3)
TIMEOUT ?= timeout
FAKERAM ?= ../RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv
PROGRAM ?= tests/programs/accumulate.c
ARCH ?= rv32i
OUT_DIR ?= build/images/accumulate-$(ARCH)
CPU2026_DIR ?= ../RISC-V-CPU-2026
TESTCASES ?= $(CPU2026_DIR)/testcases
OFFICIAL_BUILD ?= build/official
DUAL_BUILD ?= build/official-dual
FE_WIDTH ?= 1
BE_WIDTH ?= 1
PHYS_REGS ?= 64
ROB_ENTRIES ?= 32
CONFIG_SUFFIX := $(if $(filter 64-32,$(PHYS_REGS)-$(ROB_ENTRIES)),,-p$(PHYS_REGS)-r$(ROB_ENTRIES))
CONFIGURED_BUILD ?= build/official-$(FE_WIDTH)x$(BE_WIDTH)$(CONFIG_SUFFIX)
FILELIST ?= verilog/filelist.f
JOBS ?= 4
APPIMAGE ?=
MAX_CYCLES ?= 30000000
LATENCY ?= 10
Case ?=
MODE ?= opt
CLOCK_PERIOD_NS ?= 2.0
SYNTH_OUT ?= build/synth
SYNTH_JOBS ?= 2
SYNTH_TIMEOUT ?= 1800
YOSYS ?= $(abspath .deps/yosys/bin/yosys)
ABC ?= $(abspath .deps/yosys/bin/yosys-abc)
STA ?= .deps/opensta/bin/sta
ASAP7_LIB ?= .deps/asap7/lib
PERF_CONFIG_JOBS ?= 2
PERF_BUILD_TIMEOUT ?= 600
PERF_CASE_TIMEOUT ?= 1800
PERF_REPORT ?= reports/performance.json
PERF_BUILD_ROOT ?= build/performance
SYNTH_REPORT ?= reports/synthesis-matrix.json
MATRIX_REPORT ?= reports/matrix.json
REPORT_OUT ?= reports/performance-comparison

CORE_RTL := \
	rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
	rtl/rv32_fetch_pipeline.v rtl/rv32_physical_register_file.v \
	rtl/rv32_rename_unit.v rtl/rv32_decode_rename_dispatch.v \
	rtl/rv32_reorder_buffer.v rtl/rv32_integer_reservation_station.v \
	rtl/rv32i_alu.v rtl/rv32m_multiplier.v rtl/rv32m_divider.v \
	rtl/rv32_mdu_reservation_stations.v \
	rtl/rv32_memory_reservation_station.v \
	rtl/rv32_load_store_queue.v \
	rtl/rv32_completion_writeback_network.v rtl/rv32_issue_arbiter.v rtl/rv32_cpu_core.v

doctor:
	@./tools/doctor.sh

image:
	@$(TIMEOUT) 120 $(PYTHON) tools/make_image.py $(PROGRAM) --arch $(ARCH) --out-dir $(OUT_DIR)

image-test:
	@$(TIMEOUT) 120 $(PYTHON) tools/test_image_pipeline.py

lint: issue-lint core-lint memory-lint main-memory-lint icache-lint dcache-lint cache-bridge-lint predictor-lint fetch-lint dispatch-lint
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl -s rv32im_decoder \
		-o build/rv32im_decoder_lint.vvp rtl/rv32im_decoder.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl -s rv32i_alu \
		-o build/rv32i_alu_lint.vvp rtl/rv32i_alu.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl -s rv32m_multiplier \
		-o build/rv32m_multiplier_lint.vvp rtl/rv32m_multiplier.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl -s rv32m_divider \
		-o build/rv32m_divider_lint.vvp rtl/rv32m_divider.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_physical_register_file \
		-o build/rv32_physical_register_file_lint.vvp \
		rtl/rv32_physical_register_file.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_rename_unit -o build/rv32_rename_unit_lint.vvp \
		rtl/rv32_rename_unit.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_reorder_buffer -o build/rv32_reorder_buffer_lint.vvp \
		rtl/rv32_reorder_buffer.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_integer_reservation_station \
		-o build/rv32_integer_reservation_station_lint.vvp \
		rtl/rv32_integer_reservation_station.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_multiply_reservation_station \
		-o build/rv32_multiply_reservation_station_lint.vvp \
		rtl/rv32m_multiplier.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_divide_reservation_station \
		-o build/rv32_divide_reservation_station_lint.vvp \
		rtl/rv32m_divider.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32im_decoder.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32i_alu.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32m_multiplier.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32m_divider.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32_physical_register_file.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32_rename_unit.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32_reorder_buffer.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32_integer_reservation_station.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		--top-module rv32_multiply_reservation_station -Irtl \
		rtl/rv32m_multiplier.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		--top-module rv32_divide_reservation_station -Irtl \
		rtl/rv32m_divider.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32im_decoder.v; hierarchy -check -top rv32im_decoder; proc; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32i_alu.v; hierarchy -check -top rv32i_alu; proc; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32m_multiplier.v; hierarchy -check -top rv32m_multiplier; proc; opt; select -assert-none t:$$mul; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32m_divider.v; hierarchy -check -top rv32m_divider; proc; opt; select -assert-none t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32_physical_register_file.v; hierarchy -check -top rv32_physical_register_file; proc; memory; opt; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_rename_unit.v; hierarchy -check -top rv32_rename_unit; proc; memory; opt; select -assert-none t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_reorder_buffer.v; chparam -set ROB_ENTRIES 16 -set ROB_INDEX_WIDTH 4 -set ROB_TAG_WIDTH 6 -set BE_WIDTH 1 rv32_reorder_buffer; hierarchy -check -top rv32_reorder_buffer; proc; memory; opt; select -assert-none t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_reorder_buffer.v; chparam -set ROB_ENTRIES 32 -set ROB_INDEX_WIDTH 5 -set ROB_TAG_WIDTH 7 -set BE_WIDTH 2 rv32_reorder_buffer; hierarchy -check -top rv32_reorder_buffer; proc; memory; opt; select -assert-none t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 120 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_reorder_buffer.v; chparam -set ROB_ENTRIES 64 -set ROB_INDEX_WIDTH 6 -set ROB_TAG_WIDTH 8 -set BE_WIDTH 4 rv32_reorder_buffer; hierarchy -check -top rv32_reorder_buffer; proc; memory; opt; select -assert-none t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_integer_reservation_station.v; chparam -set INT_RS_ENTRIES 4 -set INT_RS_INDEX_WIDTH 2 -set BE_WIDTH 1 -set PHYS_REGS 48 -set PHYS_REG_ADDR_WIDTH 6 -set ROB_ENTRIES 16 -set ROB_INDEX_WIDTH 4 -set ROB_TAG_WIDTH 6 rv32_integer_reservation_station; hierarchy -check -top rv32_integer_reservation_station; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_integer_reservation_station.v; chparam -set INT_RS_ENTRIES 8 -set INT_RS_INDEX_WIDTH 3 -set BE_WIDTH 2 -set PHYS_REGS 64 -set PHYS_REG_ADDR_WIDTH 6 -set ROB_ENTRIES 32 -set ROB_INDEX_WIDTH 5 -set ROB_TAG_WIDTH 7 rv32_integer_reservation_station; hierarchy -check -top rv32_integer_reservation_station; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_integer_reservation_station.v; chparam -set INT_RS_ENTRIES 16 -set INT_RS_INDEX_WIDTH 4 -set BE_WIDTH 4 -set PHYS_REGS 96 -set PHYS_REG_ADDR_WIDTH 7 -set ROB_ENTRIES 64 -set ROB_INDEX_WIDTH 6 -set ROB_TAG_WIDTH 8 rv32_integer_reservation_station; hierarchy -check -top rv32_integer_reservation_station; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32m_multiplier.v rtl/rv32m_divider.v rtl/rv32_mdu_reservation_stations.v; chparam -set MUL_RS_ENTRIES 8 -set MUL_RS_INDEX_WIDTH 3 -set BE_WIDTH 4 -set PHYS_REGS 96 -set PHYS_REG_ADDR_WIDTH 7 -set ROB_ENTRIES 64 -set ROB_INDEX_WIDTH 6 -set ROB_TAG_WIDTH 8 rv32_multiply_reservation_station; hierarchy -check -top rv32_multiply_reservation_station; proc; memory; opt; select -assert-none t:$$dlatch t:$$mul t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32m_multiplier.v rtl/rv32m_divider.v rtl/rv32_mdu_reservation_stations.v; chparam -set DIV_RS_ENTRIES 8 -set DIV_RS_INDEX_WIDTH 3 -set BE_WIDTH 4 -set PHYS_REGS 96 -set PHYS_REG_ADDR_WIDTH 7 -set ROB_ENTRIES 64 -set ROB_INDEX_WIDTH 6 -set ROB_TAG_WIDTH 8 rv32_divide_reservation_station; hierarchy -check -top rv32_divide_reservation_station; proc; memory; opt; select -assert-none t:$$dlatch t:$$mul t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network.BE_WIDTH=1 \
		-P rv32_completion_writeback_network.SOURCE_COUNT=3 \
		-P rv32_completion_writeback_network.PHYS_REGS=48 \
		-P rv32_completion_writeback_network.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_completion_writeback_network.ROB_TAG_WIDTH=6 \
		-s rv32_completion_writeback_network \
		-o build/rv32_completion_writeback_network_lint_1x3.vvp \
		rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network.BE_WIDTH=2 \
		-P rv32_completion_writeback_network.SOURCE_COUNT=4 \
		-s rv32_completion_writeback_network \
		-o build/rv32_completion_writeback_network_lint_2x4.vvp \
		rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network.BE_WIDTH=4 \
		-P rv32_completion_writeback_network.SOURCE_COUNT=6 \
		-P rv32_completion_writeback_network.PHYS_REGS=96 \
		-P rv32_completion_writeback_network.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_completion_writeback_network.ROB_TAG_WIDTH=8 \
		-s rv32_completion_writeback_network \
		-o build/rv32_completion_writeback_network_lint_4x6.vvp \
		rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-GBE_WIDTH=1 -GSOURCE_COUNT=3 -GPHYS_REGS=48 \
		-GPHYS_REG_ADDR_WIDTH=6 -GROB_TAG_WIDTH=6 \
		-Irtl rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-GBE_WIDTH=2 -GSOURCE_COUNT=4 \
		-Irtl rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-GBE_WIDTH=4 -GSOURCE_COUNT=6 -GPHYS_REGS=96 \
		-GPHYS_REG_ADDR_WIDTH=7 -GROB_TAG_WIDTH=8 \
		-Irtl rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS rtl/rv32_completion_writeback_network.v; chparam -set BE_WIDTH 1 -set SOURCE_COUNT 3 -set PHYS_REGS 48 -set PHYS_REG_ADDR_WIDTH 6 -set ROB_TAG_WIDTH 6 rv32_completion_writeback_network; hierarchy -check -top rv32_completion_writeback_network; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS rtl/rv32_completion_writeback_network.v; chparam -set BE_WIDTH 2 -set SOURCE_COUNT 4 rv32_completion_writeback_network; hierarchy -check -top rv32_completion_writeback_network; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -D SYNTHESIS rtl/rv32_completion_writeback_network.v; chparam -set BE_WIDTH 4 -set SOURCE_COUNT 6 -set PHYS_REGS 96 -set PHYS_REG_ADDR_WIDTH 7 -set ROB_TAG_WIDTH 8 rv32_completion_writeback_network; hierarchy -check -top rv32_completion_writeback_network; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'

unit: issue-unit core-unit memory-unit main-memory-unit icache-unit dcache-unit cache-bridge-unit predictor-unit fetch-unit dispatch-unit
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32im_decoder_tb -o build/rv32im_decoder_tb.vvp \
		rtl/rv32im_decoder.v tb/rv32im_decoder_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32im_decoder_tb.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32i_alu_tb -o build/rv32i_alu_tb.vvp \
		rtl/rv32i_alu.v tb/rv32i_alu_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32i_alu_tb.vvp
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_multiplier_vectors.py \
		build/multiplier_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32m_multiplier_tb.ROB_TAG_WIDTH=1 \
		-s rv32m_multiplier_tb -o build/rv32m_multiplier_tb_1.vvp \
		rtl/rv32m_multiplier.v tb/rv32m_multiplier_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32m_multiplier_tb_1.vvp \
		+VECTOR_FILE=build/multiplier_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32m_multiplier_tb.ROB_TAG_WIDTH=5 \
		-s rv32m_multiplier_tb -o build/rv32m_multiplier_tb_5.vvp \
		rtl/rv32m_multiplier.v tb/rv32m_multiplier_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32m_multiplier_tb_5.vvp \
		+VECTOR_FILE=build/multiplier_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32m_multiplier_tb.ROB_TAG_WIDTH=7 \
		-s rv32m_multiplier_tb -o build/rv32m_multiplier_tb_7.vvp \
		rtl/rv32m_multiplier.v tb/rv32m_multiplier_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32m_multiplier_tb_7.vvp \
		+VECTOR_FILE=build/multiplier_vectors.txt
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_divider_vectors.py \
		build/divider_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32m_divider_tb.ROB_TAG_WIDTH=1 \
		-s rv32m_divider_tb -o build/rv32m_divider_tb_1.vvp \
		rtl/rv32m_divider.v tb/rv32m_divider_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32m_divider_tb_1.vvp \
		+VECTOR_FILE=build/divider_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32m_divider_tb.ROB_TAG_WIDTH=5 \
		-s rv32m_divider_tb -o build/rv32m_divider_tb_5.vvp \
		rtl/rv32m_divider.v tb/rv32m_divider_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32m_divider_tb_5.vvp \
		+VECTOR_FILE=build/divider_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32m_divider_tb.ROB_TAG_WIDTH=7 \
		-s rv32m_divider_tb -o build/rv32m_divider_tb_7.vvp \
		rtl/rv32m_divider.v tb/rv32m_divider_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32m_divider_tb_7.vvp \
		+VECTOR_FILE=build/divider_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_physical_register_file_tb.PHYS_REGS=64 \
		-P rv32_physical_register_file_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_physical_register_file_tb.BE_WIDTH=1 \
		-s rv32_physical_register_file_tb \
		-o build/rv32_physical_register_file_tb_64x1.vvp \
		rtl/rv32_physical_register_file.v \
		tb/rv32_physical_register_file_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_physical_register_file_tb_64x1.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_physical_register_file_tb.PHYS_REGS=48 \
		-P rv32_physical_register_file_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_physical_register_file_tb.BE_WIDTH=2 \
		-s rv32_physical_register_file_tb \
		-o build/rv32_physical_register_file_tb_48x2.vvp \
		rtl/rv32_physical_register_file.v \
		tb/rv32_physical_register_file_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_physical_register_file_tb_48x2.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_physical_register_file_tb.PHYS_REGS=96 \
		-P rv32_physical_register_file_tb.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_physical_register_file_tb.BE_WIDTH=4 \
		-s rv32_physical_register_file_tb \
		-o build/rv32_physical_register_file_tb_96x4.vvp \
		rtl/rv32_physical_register_file.v \
		tb/rv32_physical_register_file_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_physical_register_file_tb_96x4.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_physical_register_file_tb.PHYS_REGS=32 \
		-P rv32_physical_register_file_tb.PHYS_REG_ADDR_WIDTH=5 \
		-P rv32_physical_register_file_tb.BE_WIDTH=1 \
		-s rv32_physical_register_file_tb \
		-o build/rv32_physical_register_file_tb_bad_count.vvp \
		rtl/rv32_physical_register_file.v \
		tb/rv32_physical_register_file_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_physical_register_file_tb_bad_count.vvp 2>&1 | \
		grep -q '^ERROR rv32_physical_register_file PHYS_REGS='
	@echo "PASS rejected invalid PHYS_REGS"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_physical_register_file_tb.PHYS_REGS=64 \
		-P rv32_physical_register_file_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_physical_register_file_tb.BE_WIDTH=3 \
		-s rv32_physical_register_file_tb \
		-o build/rv32_physical_register_file_tb_bad_be.vvp \
		rtl/rv32_physical_register_file.v \
		tb/rv32_physical_register_file_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_physical_register_file_tb_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_physical_register_file invalid BE_WIDTH='
	@echo "PASS rejected invalid BE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_physical_register_file_tb.PHYS_REGS=48 \
		-P rv32_physical_register_file_tb.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_physical_register_file_tb.BE_WIDTH=2 \
		-s rv32_physical_register_file_tb \
		-o build/rv32_physical_register_file_tb_bad_addr.vvp \
		rtl/rv32_physical_register_file.v \
		tb/rv32_physical_register_file_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_physical_register_file_tb_bad_addr.vvp 2>&1 | \
		grep -q '^ERROR rv32_physical_register_file address width='
	@echo "PASS rejected invalid PHYS_REG_ADDR_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_rename_unit_tb.PHYS_REGS=33 \
		-P rv32_rename_unit_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_rename_unit_tb.BE_WIDTH=1 \
		-s rv32_rename_unit_tb \
		-o build/rv32_rename_unit_tb_33x1.vvp \
		rtl/rv32_rename_unit.v tb/rv32_rename_unit_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_rename_unit_tb_33x1.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_rename_unit_tb.PHYS_REGS=48 \
		-P rv32_rename_unit_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_rename_unit_tb.BE_WIDTH=2 \
		-s rv32_rename_unit_tb \
		-o build/rv32_rename_unit_tb_48x2.vvp \
		rtl/rv32_rename_unit.v tb/rv32_rename_unit_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_rename_unit_tb_48x2.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_rename_unit_tb.PHYS_REGS=64 \
		-P rv32_rename_unit_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_rename_unit_tb.BE_WIDTH=4 \
		-s rv32_rename_unit_tb \
		-o build/rv32_rename_unit_tb_64x4.vvp \
		rtl/rv32_rename_unit.v tb/rv32_rename_unit_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_rename_unit_tb_64x4.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_rename_unit_tb.PHYS_REGS=96 \
		-P rv32_rename_unit_tb.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_rename_unit_tb.BE_WIDTH=4 \
		-s rv32_rename_unit_tb \
		-o build/rv32_rename_unit_tb_96x4.vvp \
		rtl/rv32_rename_unit.v tb/rv32_rename_unit_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_rename_unit_tb_96x4.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_rename_unit.PHYS_REGS=32 \
		-P rv32_rename_unit.PHYS_REG_ADDR_WIDTH=5 \
		-P rv32_rename_unit.BE_WIDTH=1 \
		-s rv32_rename_unit -o build/rv32_rename_unit_bad_count.vvp \
		rtl/rv32_rename_unit.v
	@$(TIMEOUT) 30 vvp -N build/rv32_rename_unit_bad_count.vvp 2>&1 | \
		grep -q '^ERROR rv32_rename_unit PHYS_REGS='
	@echo "PASS rename unit rejected invalid PHYS_REGS"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_rename_unit.PHYS_REGS=64 \
		-P rv32_rename_unit.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_rename_unit.BE_WIDTH=3 \
		-s rv32_rename_unit -o build/rv32_rename_unit_bad_be.vvp \
		rtl/rv32_rename_unit.v
	@$(TIMEOUT) 30 vvp -N build/rv32_rename_unit_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_rename_unit invalid BE_WIDTH='
	@echo "PASS rename unit rejected invalid BE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_rename_unit.PHYS_REGS=48 \
		-P rv32_rename_unit.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_rename_unit.BE_WIDTH=2 \
		-s rv32_rename_unit -o build/rv32_rename_unit_bad_addr.vvp \
		rtl/rv32_rename_unit.v
	@$(TIMEOUT) 30 vvp -N build/rv32_rename_unit_bad_addr.vvp 2>&1 | \
		grep -q '^ERROR rv32_rename_unit address width='
	@echo "PASS rename unit rejected invalid PHYS_REG_ADDR_WIDTH"
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_rob_vectors.py \
		build/rob_vectors_16x1.txt --entries 16 --width 1
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_reorder_buffer_tb.ROB_ENTRIES=16 \
		-P rv32_reorder_buffer_tb.ROB_INDEX_WIDTH=4 \
		-P rv32_reorder_buffer_tb.BE_WIDTH=1 \
		-s rv32_reorder_buffer_tb \
		-o build/rv32_reorder_buffer_tb_16x1.vvp \
		rtl/rv32_reorder_buffer.v tb/rv32_reorder_buffer_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_reorder_buffer_tb_16x1.vvp \
		+VECTOR_FILE=build/rob_vectors_16x1.txt
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_rob_vectors.py \
		build/rob_vectors_32x2.txt --entries 32 --width 2
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_reorder_buffer_tb.ROB_ENTRIES=32 \
		-P rv32_reorder_buffer_tb.ROB_INDEX_WIDTH=5 \
		-P rv32_reorder_buffer_tb.BE_WIDTH=2 \
		-s rv32_reorder_buffer_tb \
		-o build/rv32_reorder_buffer_tb_32x2.vvp \
		rtl/rv32_reorder_buffer.v tb/rv32_reorder_buffer_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_reorder_buffer_tb_32x2.vvp \
		+VECTOR_FILE=build/rob_vectors_32x2.txt
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_rob_vectors.py \
		build/rob_vectors_64x4.txt --entries 64 --width 4
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_reorder_buffer_tb.ROB_ENTRIES=64 \
		-P rv32_reorder_buffer_tb.ROB_INDEX_WIDTH=6 \
		-P rv32_reorder_buffer_tb.BE_WIDTH=4 \
		-s rv32_reorder_buffer_tb \
		-o build/rv32_reorder_buffer_tb_64x4.vvp \
		rtl/rv32_reorder_buffer.v tb/rv32_reorder_buffer_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_reorder_buffer_tb_64x4.vvp \
		+VECTOR_FILE=build/rob_vectors_64x4.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_reorder_buffer.ROB_ENTRIES=24 \
		-P rv32_reorder_buffer.ROB_INDEX_WIDTH=5 \
		-P rv32_reorder_buffer.ROB_TAG_WIDTH=7 \
		-s rv32_reorder_buffer \
		-o build/rv32_reorder_buffer_bad_entries.vvp \
		rtl/rv32_reorder_buffer.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_reorder_buffer_bad_entries.vvp 2>&1 | \
		grep -q '^ERROR rv32_reorder_buffer ROB_ENTRIES not power of two='
	@echo "PASS reorder buffer rejected non-power-of-two entries"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_reorder_buffer.BE_WIDTH=3 \
		-s rv32_reorder_buffer \
		-o build/rv32_reorder_buffer_bad_be.vvp \
		rtl/rv32_reorder_buffer.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_reorder_buffer_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_reorder_buffer invalid BE_WIDTH='
	@echo "PASS reorder buffer rejected invalid BE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_reorder_buffer.ROB_TAG_WIDTH=6 \
		-s rv32_reorder_buffer \
		-o build/rv32_reorder_buffer_bad_tag.vvp \
		rtl/rv32_reorder_buffer.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_reorder_buffer_bad_tag.vvp 2>&1 | \
		grep -q '^ERROR rv32_reorder_buffer tag width='
	@echo "PASS reorder buffer rejected invalid ROB_TAG_WIDTH"
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_int_rs_vectors.py \
		build/int_rs_vectors_4x1.txt --entries 4 --width 1 \
		--phys-regs 48 --rob-entries 16
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_integer_reservation_station_tb.INT_RS_ENTRIES=4 \
		-P rv32_integer_reservation_station_tb.INT_RS_INDEX_WIDTH=2 \
		-P rv32_integer_reservation_station_tb.BE_WIDTH=1 \
		-P rv32_integer_reservation_station_tb.PHYS_REGS=48 \
		-P rv32_integer_reservation_station_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_integer_reservation_station_tb.ROB_ENTRIES=16 \
		-P rv32_integer_reservation_station_tb.ROB_INDEX_WIDTH=4 \
		-s rv32_integer_reservation_station_tb \
		-o build/rv32_integer_reservation_station_tb_4x1.vvp \
		rtl/rv32_integer_reservation_station.v \
		tb/rv32_integer_reservation_station_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_integer_reservation_station_tb_4x1.vvp \
		+VECTOR_FILE=build/int_rs_vectors_4x1.txt
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_int_rs_vectors.py \
		build/int_rs_vectors_8x2.txt --entries 8 --width 2 \
		--phys-regs 64 --rob-entries 32
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_integer_reservation_station_tb.INT_RS_ENTRIES=8 \
		-P rv32_integer_reservation_station_tb.INT_RS_INDEX_WIDTH=3 \
		-P rv32_integer_reservation_station_tb.BE_WIDTH=2 \
		-P rv32_integer_reservation_station_tb.PHYS_REGS=64 \
		-P rv32_integer_reservation_station_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_integer_reservation_station_tb.ROB_ENTRIES=32 \
		-P rv32_integer_reservation_station_tb.ROB_INDEX_WIDTH=5 \
		-s rv32_integer_reservation_station_tb \
		-o build/rv32_integer_reservation_station_tb_8x2.vvp \
		rtl/rv32_integer_reservation_station.v \
		tb/rv32_integer_reservation_station_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_integer_reservation_station_tb_8x2.vvp \
		+VECTOR_FILE=build/int_rs_vectors_8x2.txt
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_int_rs_vectors.py \
		build/int_rs_vectors_16x4.txt --entries 16 --width 4 \
		--phys-regs 96 --rob-entries 64
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_integer_reservation_station_tb.INT_RS_ENTRIES=16 \
		-P rv32_integer_reservation_station_tb.INT_RS_INDEX_WIDTH=4 \
		-P rv32_integer_reservation_station_tb.BE_WIDTH=4 \
		-P rv32_integer_reservation_station_tb.PHYS_REGS=96 \
		-P rv32_integer_reservation_station_tb.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_integer_reservation_station_tb.ROB_ENTRIES=64 \
		-P rv32_integer_reservation_station_tb.ROB_INDEX_WIDTH=6 \
		-s rv32_integer_reservation_station_tb \
		-o build/rv32_integer_reservation_station_tb_16x4.vvp \
		rtl/rv32_integer_reservation_station.v \
		tb/rv32_integer_reservation_station_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_integer_reservation_station_tb_16x4.vvp \
		+VECTOR_FILE=build/int_rs_vectors_16x4.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_integer_reservation_station.INT_RS_ENTRIES=6 \
		-P rv32_integer_reservation_station.INT_RS_INDEX_WIDTH=3 \
		-s rv32_integer_reservation_station \
		-o build/rv32_integer_reservation_station_bad_entries.vvp \
		rtl/rv32_integer_reservation_station.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_integer_reservation_station_bad_entries.vvp 2>&1 | \
		grep -q '^ERROR rv32_integer_reservation_station INT_RS_ENTRIES not power of two='
	@echo "PASS integer reservation station rejected invalid entries"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_integer_reservation_station.BE_WIDTH=3 \
		-s rv32_integer_reservation_station \
		-o build/rv32_integer_reservation_station_bad_be.vvp \
		rtl/rv32_integer_reservation_station.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_integer_reservation_station_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_integer_reservation_station invalid BE_WIDTH='
	@echo "PASS integer reservation station rejected invalid BE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_integer_reservation_station.INT_RS_INDEX_WIDTH=4 \
		-s rv32_integer_reservation_station \
		-o build/rv32_integer_reservation_station_bad_index.vvp \
		rtl/rv32_integer_reservation_station.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_integer_reservation_station_bad_index.vvp 2>&1 | \
		grep -q '^ERROR rv32_integer_reservation_station index width='
	@echo "PASS integer reservation station rejected invalid index width"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_integer_reservation_station.PHYS_REG_ADDR_WIDTH=7 \
		-s rv32_integer_reservation_station \
		-o build/rv32_integer_reservation_station_bad_phys.vvp \
		rtl/rv32_integer_reservation_station.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_integer_reservation_station_bad_phys.vvp 2>&1 | \
		grep -q '^ERROR rv32_integer_reservation_station physical address width='
	@echo "PASS integer reservation station rejected invalid physical address width"
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_mdu_rs_vectors.py \
		build/mdu_rs_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_mdu_reservation_stations_tb.RS_ENTRIES=2 \
		-P rv32_mdu_reservation_stations_tb.RS_INDEX_WIDTH=1 \
		-P rv32_mdu_reservation_stations_tb.BE_WIDTH=1 \
		-P rv32_mdu_reservation_stations_tb.PHYS_REGS=48 \
		-P rv32_mdu_reservation_stations_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_mdu_reservation_stations_tb.ROB_ENTRIES=16 \
		-P rv32_mdu_reservation_stations_tb.ROB_INDEX_WIDTH=4 \
		-s rv32_mdu_reservation_stations_tb \
		-o build/rv32_mdu_reservation_stations_tb_2x1.vvp \
		rtl/rv32m_multiplier.v rtl/rv32m_divider.v \
		rtl/rv32_mdu_reservation_stations.v \
		tb/rv32_mdu_reservation_stations_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_mdu_reservation_stations_tb_2x1.vvp \
		+VECTOR_FILE=build/mdu_rs_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_mdu_reservation_stations_tb.RS_ENTRIES=4 \
		-P rv32_mdu_reservation_stations_tb.RS_INDEX_WIDTH=2 \
		-P rv32_mdu_reservation_stations_tb.BE_WIDTH=2 \
		-P rv32_mdu_reservation_stations_tb.PHYS_REGS=64 \
		-P rv32_mdu_reservation_stations_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_mdu_reservation_stations_tb.ROB_ENTRIES=32 \
		-P rv32_mdu_reservation_stations_tb.ROB_INDEX_WIDTH=5 \
		-s rv32_mdu_reservation_stations_tb \
		-o build/rv32_mdu_reservation_stations_tb_4x2.vvp \
		rtl/rv32m_multiplier.v rtl/rv32m_divider.v \
		rtl/rv32_mdu_reservation_stations.v \
		tb/rv32_mdu_reservation_stations_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_mdu_reservation_stations_tb_4x2.vvp \
		+VECTOR_FILE=build/mdu_rs_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_mdu_reservation_stations_tb.RS_ENTRIES=8 \
		-P rv32_mdu_reservation_stations_tb.RS_INDEX_WIDTH=3 \
		-P rv32_mdu_reservation_stations_tb.BE_WIDTH=4 \
		-P rv32_mdu_reservation_stations_tb.PHYS_REGS=96 \
		-P rv32_mdu_reservation_stations_tb.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_mdu_reservation_stations_tb.ROB_ENTRIES=64 \
		-P rv32_mdu_reservation_stations_tb.ROB_INDEX_WIDTH=6 \
		-s rv32_mdu_reservation_stations_tb \
		-o build/rv32_mdu_reservation_stations_tb_8x4.vvp \
		rtl/rv32m_multiplier.v rtl/rv32m_divider.v \
		rtl/rv32_mdu_reservation_stations.v \
		tb/rv32_mdu_reservation_stations_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_mdu_reservation_stations_tb_8x4.vvp \
		+VECTOR_FILE=build/mdu_rs_vectors.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_multiply_reservation_station.MUL_RS_ENTRIES=6 \
		-P rv32_multiply_reservation_station.MUL_RS_INDEX_WIDTH=3 \
		-s rv32_multiply_reservation_station \
		-o build/rv32_multiply_reservation_station_bad_entries.vvp \
		rtl/rv32m_multiplier.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_multiply_reservation_station_bad_entries.vvp 2>&1 | \
		grep -q '^ERROR rv32_mdu_reservation_station_core RS_ENTRIES not power of two='
	@echo "PASS MDU reservation station rejected invalid entries"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_multiply_reservation_station.MUL_RS_ENTRIES=2 \
		-P rv32_multiply_reservation_station.MUL_RS_INDEX_WIDTH=1 \
		-P rv32_multiply_reservation_station.BE_WIDTH=4 \
		-s rv32_multiply_reservation_station \
		-o build/rv32_multiply_reservation_station_too_small.vvp \
		rtl/rv32m_multiplier.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_multiply_reservation_station_too_small.vvp 2>&1 | \
		grep -q '^ERROR rv32_mdu_reservation_station_core invalid RS_ENTRIES='
	@echo "PASS MDU reservation station rejected undersized capacity"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_divide_reservation_station.BE_WIDTH=3 \
		-s rv32_divide_reservation_station \
		-o build/rv32_divide_reservation_station_bad_be.vvp \
		rtl/rv32m_divider.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_divide_reservation_station_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_mdu_reservation_station_core invalid BE_WIDTH='
	@echo "PASS MDU reservation station rejected invalid BE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_multiply_reservation_station.MUL_RS_INDEX_WIDTH=3 \
		-s rv32_multiply_reservation_station \
		-o build/rv32_multiply_reservation_station_bad_index.vvp \
		rtl/rv32m_multiplier.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_multiply_reservation_station_bad_index.vvp 2>&1 | \
		grep -q '^ERROR rv32_mdu_reservation_station_core index width='
	@echo "PASS MDU reservation station rejected invalid index width"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_divide_reservation_station.PHYS_REG_ADDR_WIDTH=7 \
		-s rv32_divide_reservation_station \
		-o build/rv32_divide_reservation_station_bad_phys.vvp \
		rtl/rv32m_divider.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_divide_reservation_station_bad_phys.vvp 2>&1 | \
		grep -q '^ERROR rv32_mdu_reservation_station_core physical address width='
	@echo "PASS MDU reservation station rejected invalid physical address width"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_multiply_reservation_station.ROB_TAG_WIDTH=5 \
		-s rv32_multiply_reservation_station \
		-o build/rv32_multiply_reservation_station_bad_tag.vvp \
		rtl/rv32m_multiplier.v rtl/rv32_mdu_reservation_stations.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_multiply_reservation_station_bad_tag.vvp 2>&1 | \
		grep -q '^ERROR rv32_mdu_reservation_station_core invalid ROB_TAG_WIDTH='
	@echo "PASS MDU reservation station rejected invalid ROB tag width"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_mdu_reservation_station_bad_op_tb \
		-o build/rv32_mdu_reservation_station_bad_op.vvp \
		rtl/rv32_mdu_reservation_stations.v \
		tb/rv32_mdu_reservation_stations_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_mdu_reservation_station_bad_op.vvp 2>&1 | \
		grep -q '^ERROR rv32_mdu_reservation_station_core unsupported op='
	@echo "PASS MDU reservation station rejected misclassified operation"
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_writeback_vectors.py \
		build/writeback_vectors_1x3.txt --width 1 --sources 3
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network_tb.BE_WIDTH=1 \
		-P rv32_completion_writeback_network_tb.SOURCE_COUNT=3 \
		-P rv32_completion_writeback_network_tb.PHYS_REGS=48 \
		-P rv32_completion_writeback_network_tb.PHYS_REG_ADDR_WIDTH=6 \
		-P rv32_completion_writeback_network_tb.ROB_TAG_WIDTH=6 \
		-s rv32_completion_writeback_network_tb \
		-o build/rv32_completion_writeback_network_tb_1x3.vvp \
		rtl/rv32_completion_writeback_network.v \
		tb/rv32_completion_writeback_network_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_completion_writeback_network_tb_1x3.vvp \
		+VECTOR_FILE=build/writeback_vectors_1x3.txt
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_writeback_vectors.py \
		build/writeback_vectors_2x4.txt --width 2 --sources 4
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network_tb.BE_WIDTH=2 \
		-P rv32_completion_writeback_network_tb.SOURCE_COUNT=4 \
		-s rv32_completion_writeback_network_tb \
		-o build/rv32_completion_writeback_network_tb_2x4.vvp \
		rtl/rv32_completion_writeback_network.v \
		tb/rv32_completion_writeback_network_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_completion_writeback_network_tb_2x4.vvp \
		+VECTOR_FILE=build/writeback_vectors_2x4.txt
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_writeback_vectors.py \
		build/writeback_vectors_4x6.txt --width 4 --sources 6
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network_tb.BE_WIDTH=4 \
		-P rv32_completion_writeback_network_tb.SOURCE_COUNT=6 \
		-P rv32_completion_writeback_network_tb.PHYS_REGS=96 \
		-P rv32_completion_writeback_network_tb.PHYS_REG_ADDR_WIDTH=7 \
		-P rv32_completion_writeback_network_tb.ROB_TAG_WIDTH=8 \
		-s rv32_completion_writeback_network_tb \
		-o build/rv32_completion_writeback_network_tb_4x6.vvp \
		rtl/rv32_completion_writeback_network.v \
		tb/rv32_completion_writeback_network_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_completion_writeback_network_tb_4x6.vvp \
		+VECTOR_FILE=build/writeback_vectors_4x6.txt
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_completion_writeback_integration_tb \
		-o build/rv32_completion_writeback_integration_tb.vvp \
		rtl/rv32_completion_writeback_network.v \
		rtl/rv32_reorder_buffer.v \
		rtl/rv32_physical_register_file.v \
		tb/rv32_completion_writeback_integration_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_completion_writeback_integration_tb.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network.BE_WIDTH=3 \
		-s rv32_completion_writeback_network \
		-o build/rv32_completion_writeback_network_bad_be.vvp \
		rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_completion_writeback_network_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_completion_writeback_network invalid BE_WIDTH='
	@echo "PASS writeback network rejected invalid BE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_completion_writeback_network.PHYS_REGS=48 \
		-P rv32_completion_writeback_network.PHYS_REG_ADDR_WIDTH=7 \
		-s rv32_completion_writeback_network \
		-o build/rv32_completion_writeback_network_bad_phys.vvp \
		rtl/rv32_completion_writeback_network.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_completion_writeback_network_bad_phys.vvp 2>&1 | \
		grep -q '^ERROR rv32_completion_writeback_network physical address width='
	@echo "PASS writeback network rejected invalid physical address width"

build:
	@$(TIMEOUT) 300 $(PYTHON) tools/build_configured.py \
		--framework $(CPU2026_DIR) --filelist $(FILELIST) \
		--out $(OFFICIAL_BUILD) --fe-width 1 --be-width 1 --jobs $(JOBS) \
		--appimage "$(APPIMAGE)"

build-dual:
	@$(TIMEOUT) 300 $(PYTHON) tools/build_configured.py \
		--framework $(CPU2026_DIR) --filelist $(FILELIST) \
		--out $(DUAL_BUILD) --fe-width 2 --be-width 2 --jobs $(JOBS) \
		--appimage "$(APPIMAGE)"

build-configured:
	@$(TIMEOUT) 300 $(PYTHON) tools/build_configured.py \
		--framework $(CPU2026_DIR) --filelist $(FILELIST) \
		--out $(CONFIGURED_BUILD) --fe-width $(FE_WIDTH) --be-width $(BE_WIDTH) \
		--phys-regs $(PHYS_REGS) --rob-entries $(ROB_ENTRIES) \
		--jobs $(JOBS) --appimage "$(APPIMAGE)"

smoke-configured: build-configured
	@$(PYTHON) tools/run_width_regression.py --framework $(CPU2026_DIR) \
		--testcases "$(TESTCASES)" --filelist $(FILELIST) --mode smoke \
		--fe-width $(FE_WIDTH) --be-width $(BE_WIDTH) --sim $(CONFIGURED_BUILD)/sim \
		--phys-regs $(PHYS_REGS) --rob-entries $(ROB_ENTRIES) \
		--max-cycles $(MAX_CYCLES) --latency $(LATENCY) \
		--report reports/smoke-$(FE_WIDTH)x$(BE_WIDTH)$(CONFIG_SUFFIX).json

test-configured: build-configured
	@$(PYTHON) tools/run_width_regression.py --framework $(CPU2026_DIR) \
		--testcases "$(TESTCASES)" --filelist $(FILELIST) --mode test \
		--fe-width $(FE_WIDTH) --be-width $(BE_WIDTH) --sim $(CONFIGURED_BUILD)/sim \
		--phys-regs $(PHYS_REGS) --rob-entries $(ROB_ENTRIES) \
		--max-cycles $(MAX_CYCLES) --latency $(LATENCY) \
		--report reports/correctness-$(FE_WIDTH)x$(BE_WIDTH)$(CONFIG_SUFFIX).json $(if $(Case),--case "$(Case)",)

regression-widths: lint unit
	@$(PYTHON) tools/run_width_regression.py --framework $(CPU2026_DIR) \
		--testcases "$(TESTCASES)" --filelist $(FILELIST) --jobs $(JOBS) \
		--max-cycles $(MAX_CYCLES) --latency $(LATENCY) --appimage "$(APPIMAGE)"

smoke: build
	@$(TIMEOUT) 120 $(PYTHON) tools/make_image.py \
		tests/programs/accumulate.c --arch rv32im \
		--out-dir build/images/smoke-rv32im
	@$(TIMEOUT) 300 $(PYTHON) $(CPU2026_DIR)/scripts/run.py \
		build/images/smoke-rv32im/accumulate.bin \
		--build $(OFFICIAL_BUILD) --sim $(OFFICIAL_BUILD)/sim \
		--expected 5050 --max-cycles 1000000 --latency 10
	@$(TIMEOUT) 120 $(PYTHON) tools/make_image.py \
		tests/programs/core_ooo.c --arch rv32im \
		--out-dir build/images/core-ooo-rv32im
	@$(TIMEOUT) 300 $(PYTHON) $(CPU2026_DIR)/scripts/run.py \
		build/images/core-ooo-rv32im/core_ooo.bin \
		--build $(OFFICIAL_BUILD) --sim $(OFFICIAL_BUILD)/sim \
		--expected 42 --max-cycles 1000000 --latency 10

smoke-dual: build-dual
	@$(TIMEOUT) 120 $(PYTHON) tools/make_image.py \
		tests/programs/accumulate.c --arch rv32im \
		--out-dir build/images/smoke-rv32im
	@$(TIMEOUT) 300 $(PYTHON) $(CPU2026_DIR)/scripts/run.py \
		build/images/smoke-rv32im/accumulate.bin \
		--build $(DUAL_BUILD) --sim $(DUAL_BUILD)/sim \
		--expected 5050 --max-cycles 1000000 --latency 10
	@$(TIMEOUT) 120 $(PYTHON) tools/make_image.py \
		tests/programs/core_ooo.c --arch rv32im \
		--out-dir build/images/core-ooo-rv32im
	@$(TIMEOUT) 300 $(PYTHON) $(CPU2026_DIR)/scripts/run.py \
		build/images/core-ooo-rv32im/core_ooo.bin \
		--build $(DUAL_BUILD) --sim $(DUAL_BUILD)/sim \
		--expected 42 --max-cycles 1000000 --latency 10

test: build
	@$(PYTHON) tools/run_width_regression.py --framework $(CPU2026_DIR) \
		--testcases "$(TESTCASES)" --filelist $(FILELIST) --mode test \
		--fe-width 1 --be-width 1 --sim $(OFFICIAL_BUILD)/sim \
		--max-cycles $(MAX_CYCLES) --latency $(LATENCY) \
		--report reports/correctness-1x1.json $(if $(Case),--case "$(Case)",)

test-dual: build-dual
	@$(PYTHON) tools/run_width_regression.py --framework $(CPU2026_DIR) \
		--testcases "$(TESTCASES)" --filelist $(FILELIST) --mode test \
		--fe-width 2 --be-width 2 --sim $(DUAL_BUILD)/sim \
		--max-cycles $(MAX_CYCLES) --latency $(LATENCY) \
		--report reports/correctness-2x2.json $(if $(Case),--case "$(Case)",)

regression: unit smoke test smoke-dual test-dual

matrix matrix-lint matrix-functional: matrix-unit
	@$(PYTHON) tools/run_parameter_matrix.py --framework $(CPU2026_DIR) \
		--testcases "$(TESTCASES)" --filelist $(FILELIST) --jobs $(JOBS) \
		--max-cycles $(MAX_CYCLES) --latency $(LATENCY) --appimage "$(APPIMAGE)" \
		--phase $(if $(filter matrix-lint,$@),lint,$(if $(filter matrix-functional,$@),functional,all)) \
		--report reports/$@.json

matrix-unit:
	@$(TIMEOUT) 30 $(PYTHON) tools/test_parameter_matrix.py

synth:
	@$(PYTHON) tools/run_synthesis.py --framework "$(CPU2026_DIR)" \
		--filelist "$(FILELIST)" --out "$(SYNTH_OUT)" --mode "$(MODE)" \
		--fe-width $(FE_WIDTH) --be-width $(BE_WIDTH) \
		--phys-regs $(PHYS_REGS) --rob-entries $(ROB_ENTRIES) \
		--clock-period $(CLOCK_PERIOD_NS) --timeout $(SYNTH_TIMEOUT) \
		--yosys "$(YOSYS)" --abc "$(ABC)" --sta "$(abspath $(STA))" \
		--asap7-lib "$(ASAP7_LIB)" --appimage "$(APPIMAGE)" \
		--report reports/synthesis-$(FE_WIDTH)x$(BE_WIDTH)-p$(PHYS_REGS)-r$(ROB_ENTRIES)-$(MODE).json

synth-matrix: synth-unit
	@$(PYTHON) tools/run_synthesis.py --framework "$(CPU2026_DIR)" \
		--filelist "$(FILELIST)" --out "$(SYNTH_OUT)" --mode both --matrix \
		--jobs $(SYNTH_JOBS) --clock-period $(CLOCK_PERIOD_NS) \
		--timeout $(SYNTH_TIMEOUT) --yosys "$(YOSYS)" --abc "$(ABC)" \
		--sta "$(abspath $(STA))" --asap7-lib "$(ASAP7_LIB)" \
		--appimage "$(APPIMAGE)" --report reports/synthesis-matrix.json

synth-unit:
	@$(TIMEOUT) 30 $(PYTHON) tools/test_synthesis.py

synth-setup:
	@$(PYTHON) tools/setup_synthesis.py --jobs $(JOBS)

perf-unit:
	@$(TIMEOUT) 120 $(PYTHON) tools/test_performance.py

perf: perf-unit
	@$(PYTHON) tools/run_performance.py --framework "$(CPU2026_DIR)" \
		--testcases "$(TESTCASES)" --filelist "$(FILELIST)" --jobs "$(JOBS)" \
		--config-jobs "$(PERF_CONFIG_JOBS)" --appimage "$(APPIMAGE)" \
		--max-cycles "$(MAX_CYCLES)" --latency "$(LATENCY)" \
		--build-timeout "$(PERF_BUILD_TIMEOUT)" --case-timeout "$(PERF_CASE_TIMEOUT)" \
		--build-root "$(PERF_BUILD_ROOT)" --report "$(PERF_REPORT)"

report: perf-unit
	@$(TIMEOUT) 120 $(PYTHON) tools/report_performance.py \
		--performance "$(PERF_REPORT)" --synthesis "$(SYNTH_REPORT)" \
		--matrix "$(MATRIX_REPORT)" --out "$(REPORT_OUT)"

issue-lint:
	@mkdir -p build
	@for width in 1 2 4; do \
		$(TIMEOUT) 30 iverilog -g2005 -Wall -s rv32_issue_arbiter \
			-P rv32_issue_arbiter.BE_WIDTH=$$width \
			-o build/issue_lint_$$width.vvp rtl/rv32_issue_arbiter.v || exit 1; \
		$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
			--top-module rv32_issue_arbiter -GBE_WIDTH=$$width \
			rtl/rv32_issue_arbiter.v || exit 1; \
		$(TIMEOUT) 30 yosys -q -p 'read_verilog rtl/rv32_issue_arbiter.v; chparam -set BE_WIDTH '"$$width"' rv32_issue_arbiter; hierarchy -check -top rv32_issue_arbiter; proc; opt; select -assert-none t:$$dlatch; check' || exit 1; \
	done

issue-unit:
	@mkdir -p build
	@for width in 1 2 4; do \
		$(TIMEOUT) 30 $(PYTHON) tools/generate_issue_vectors.py \
			build/issue_$$width.txt --width $$width || exit 1; \
		$(TIMEOUT) 30 iverilog -g2005 -Wall -s rv32_issue_arbiter_tb \
			-P rv32_issue_arbiter_tb.BE_WIDTH=$$width \
			-o build/issue_tb_$$width.vvp rtl/rv32_issue_arbiter.v tb/rv32_issue_arbiter_tb.v || exit 1; \
		$(TIMEOUT) 30 vvp -N build/issue_tb_$$width.vvp +VECTOR_FILE=build/issue_$$width.txt || exit 1; \
	done

core-lint:
	@mkdir -p build
	@for fe in 1 2 4; do for be in 1 2 4; do \
		$(TIMEOUT) 60 iverilog -g2005 -Wall -I rtl -s rv32_cpu_core \
			-P rv32_cpu_core.FE_WIDTH=$$fe -P rv32_cpu_core.BE_WIDTH=$$be \
			-o build/core_lint_$${fe}x$$be.vvp $(CORE_RTL) || exit 1; \
		$(TIMEOUT) 60 verilator --lint-only --language 1364-2005 -Wall \
			--top-module rv32_cpu_core -GFE_WIDTH=$$fe -GBE_WIDTH=$$be \
			-Irtl $(CORE_RTL) || exit 1; \
		$(TIMEOUT) 120 yosys -q -p 'read_verilog -D SYNTHESIS -I rtl $(CORE_RTL); chparam -set FE_WIDTH '"$$fe"' -set BE_WIDTH '"$$be"' rv32_cpu_core; hierarchy -check -top rv32_cpu_core; proc; memory; opt; select -assert-none t:$$dlatch; check' || exit 1; \
		echo "PASS core lint FE=$$fe BE=$$be"; \
	done; done

core-unit:
	@mkdir -p build/core-vectors
	@for seed in 0x2401 0x2402 0x2403; do \
		$(TIMEOUT) 30 $(PYTHON) tools/generate_core_vectors.py \
			--out build/core-vectors/$$seed --seed $$seed || exit 1; \
	done
	@for fe in 1 2 4; do for be in 1 2 4; do \
		$(TIMEOUT) 180 verilator --binary --timing --trace --assert \
			--language 1364-2005 -Wall -Wno-fatal -DRV32_TEST_WATCHDOG \
			--top-module rv32_cpu_core_width_tb -GFE_WIDTH=$$fe -GBE_WIDTH=$$be \
			--Mdir build/core_tb_$${fe}x$$be -o core_tb -Irtl \
			-j $(JOBS) $(CORE_RTL) tb/rv32_cpu_core_width_tb.v || exit 1; \
		for seed in 0x2401 0x2402 0x2403; do \
			$(TIMEOUT) 30 build/core_tb_$${fe}x$$be/core_tb \
				+PROGRAM=build/core-vectors/$$seed.words +TRACE=build/core-vectors/$$seed.trace \
				+EXPECTED=$$(cat build/core-vectors/$$seed.result) +SEED=$$((seed)) || exit 1; \
		done; \
	done; done
	@$(TIMEOUT) 30 $(PYTHON) tools/test_core_watchdog.py build/core_tb_1x1/core_tb
	@for fe in 1 2 4; do for be in 1 2 4; do \
		$(TIMEOUT) 180 verilator --binary --timing --assert \
			--language 1364-2005 -Wall -Wno-fatal \
			--top-module rv32_cpu_core_alignment_tb -GFE_WIDTH=$$fe -GBE_WIDTH=$$be \
			--Mdir build/alignment_$${fe}x$$be -o alignment_tb -Irtl \
			-j $(JOBS) $(CORE_RTL) tb/rv32_cpu_core_alignment_tb.v || exit 1; \
		for case_id in 0 1 2 3 4; do \
			$(TIMEOUT) 30 build/alignment_$${fe}x$$be/alignment_tb \
				+CASE=$$case_id || exit 1; \
		done; \
	done; done
	@for parameter in FE_WIDTH BE_WIDTH; do \
		$(TIMEOUT) 60 iverilog -g2005 -I rtl -s rv32_cpu_core \
			-P rv32_cpu_core.$$parameter=3 -o build/core_bad_$$parameter.vvp $(CORE_RTL) || exit 1; \
		$(TIMEOUT) 30 vvp -N build/core_bad_$$parameter.vvp 2>&1 | \
			grep -q '^ERROR rv32_cpu_core unsupported width configuration' || exit 1; \
	done
	@$(TIMEOUT) 30 $(PYTHON) tools/generate_writeback_vectors.py build/writeback_vectors_4x7.txt --width 4 --sources 7
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl -s rv32_completion_writeback_network_tb \
		-P rv32_completion_writeback_network_tb.BE_WIDTH=4 \
		-P rv32_completion_writeback_network_tb.SOURCE_COUNT=7 \
		-o build/writeback_4x7.vvp rtl/rv32_completion_writeback_network.v tb/rv32_completion_writeback_network_tb.v
	@$(TIMEOUT) 30 vvp -N build/writeback_4x7.vvp +VECTOR_FILE=build/writeback_vectors_4x7.txt
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl -s rv32_completion_writeback_integration_tb \
		-P rv32_completion_writeback_integration_tb.BE_WIDTH=4 \
		-P rv32_completion_writeback_integration_tb.SOURCE_COUNT=7 \
		-o build/writeback_integration_4x7.vvp rtl/rv32_completion_writeback_network.v \
			rtl/rv32_reorder_buffer.v rtl/rv32_physical_register_file.v tb/rv32_completion_writeback_integration_tb.v
	@$(TIMEOUT) 30 vvp -N build/writeback_integration_4x7.vvp

memory-lint:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl \
		-s rv32_memory_reservation_station \
		-o build/rv32_memory_reservation_station_lint.vvp \
		rtl/rv32_memory_reservation_station.v
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl \
		-s rv32_load_store_queue -o build/rv32_load_store_queue_lint.vvp \
		rtl/rv32_load_store_queue.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32_memory_reservation_station.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32_load_store_queue.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-GBE_WIDTH=4 -GRS_ENTRIES=16 -GRS_INDEX_WIDTH=4 \
		-Irtl rtl/rv32_memory_reservation_station.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-GBE_WIDTH=4 -GLSQ_ENTRIES=16 -GLSQ_INDEX_WIDTH=4 \
		-GLSQ_TAG_WIDTH=6 -Irtl rtl/rv32_load_store_queue.v
	@$(TIMEOUT) 120 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_memory_reservation_station.v; hierarchy -check -top rv32_memory_reservation_station; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check'
	@$(TIMEOUT) 120 yosys -q -p \
		'read_verilog -D SYNTHESIS -I rtl rtl/rv32_load_store_queue.v; hierarchy -check -top rv32_load_store_queue; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check'

memory-unit:
	@mkdir -p build
	@for width in 1 2 4; do \
		for kind in 0 1; do \
			$(TIMEOUT) 30 iverilog -g2005 -I rtl \
				-P rv32_memory_reservation_station_tb.BE_WIDTH=$$width \
				-P rv32_memory_reservation_station_tb.IS_STORE=$$kind \
				-s rv32_memory_reservation_station_tb \
				-o build/memory_rs_$${width}_$${kind}.vvp \
				rtl/rv32_memory_reservation_station.v \
				tb/rv32_memory_reservation_station_tb.v || exit 1; \
			$(TIMEOUT) 30 vvp -N build/memory_rs_$${width}_$${kind}.vvp || exit 1; \
		done; \
		do_entries=8; do_index=3; \
		if [ $$width -eq 4 ]; then do_entries=16; do_index=4; fi; \
		$(TIMEOUT) 30 iverilog -g2005 -I rtl \
			-P rv32_load_store_queue_tb.BE_WIDTH=$$width \
			-P rv32_load_store_queue_tb.LSQ_ENTRIES=$$do_entries \
			-P rv32_load_store_queue_tb.LSQ_INDEX_WIDTH=$$do_index \
			-s rv32_load_store_queue_tb -o build/lsq_$$width.vvp \
			rtl/rv32_load_store_queue.v tb/rv32_load_store_queue_tb.v || exit 1; \
		$(TIMEOUT) 30 vvp -N build/lsq_$$width.vvp || exit 1; \
	done
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl \
		-s rv32_lsq_rob_integration_tb -o build/lsq_rob_integration.vvp \
		rtl/rv32_load_store_queue.v rtl/rv32_completion_writeback_network.v \
		rtl/rv32_reorder_buffer.v tb/rv32_lsq_rob_integration_tb.v
	@$(TIMEOUT) 30 vvp -N build/lsq_rob_integration.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl \
		-P rv32_load_store_queue.LSQ_ENTRIES=6 \
		-s rv32_load_store_queue -o build/lsq_bad_capacity.vvp \
		rtl/rv32_load_store_queue.v
	@$(TIMEOUT) 30 vvp -N build/lsq_bad_capacity.vvp 2>&1 | \
		grep -q '^ERROR rv32_load_store_queue invalid parameters'
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl \
		-P rv32_memory_reservation_station.BE_WIDTH=3 \
		-s rv32_memory_reservation_station \
		-o build/memory_rs_bad_width.vvp \
		rtl/rv32_memory_reservation_station.v
	@$(TIMEOUT) 30 vvp -N build/memory_rs_bad_width.vvp 2>&1 | \
		grep -q '^ERROR rv32_memory_reservation_station invalid parameters'

main-memory-lint:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall \
		-s rv32_main_memory -o build/rv32_main_memory_lint.vvp \
		tb/rv32_main_memory.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		--top-module rv32_main_memory tb/rv32_main_memory.v

main-memory-unit:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall \
		-s rv32_main_memory_tb -o build/rv32_main_memory_tb.vvp \
		tb/rv32_main_memory.v tb/rv32_main_memory_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_main_memory_tb.vvp
	@$(TIMEOUT) 120 $(PYTHON) tools/make_image.py \
		tests/programs/accumulate.c --arch rv32i \
		--out-dir build/images/main-memory-rv32i
	@$(TIMEOUT) 30 vvp -N build/rv32_main_memory_tb.vvp \
		+MEM_IMAGE=build/images/main-memory-rv32i/accumulate.image \
		+CHECK_IMAGE

icache-lint:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -i -Wall \
		-s rv32_l1_instruction_cache \
		-o build/rv32_l1_instruction_cache_2005.vvp \
		rtl/rv32_l1_instruction_cache.v
	@$(TIMEOUT) 30 iverilog -g2012 -Wall \
		-s rv32_l1_instruction_cache \
		-o build/rv32_l1_instruction_cache_lint.vvp \
		$(FAKERAM) rtl/rv32_l1_instruction_cache.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1800-2012 -Wall \
		-Wno-TIMESCALEMOD -Wno-BLKSEQ \
		--top-module rv32_l1_instruction_cache \
		$(FAKERAM) rtl/rv32_l1_instruction_cache.v
	@$(TIMEOUT) 120 yosys -q -p \
		'read_verilog -sv -D SYNTHESIS $(FAKERAM) rtl/rv32_l1_instruction_cache.v; hierarchy -check -top rv32_l1_instruction_cache; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check'

icache-unit:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2012 -Wall \
		-s rv32_l1_instruction_cache_tb \
		-o build/rv32_l1_instruction_cache_tb.vvp \
		$(FAKERAM) rtl/rv32_l1_instruction_cache.v \
		tb/rv32_main_memory.v tb/rv32_l1_instruction_cache_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_l1_instruction_cache_tb.vvp
	@$(TIMEOUT) 30 iverilog -g2012 -Wall \
		-s rv32_l1_cache_parameter_tb \
		-o build/rv32_l1_cache_parameter_tb.vvp \
		$(FAKERAM) rtl/rv32_l1_instruction_cache.v \
		rtl/rv32_l1_data_cache.v tb/rv32_main_memory.v \
		tb/rv32_l1_cache_parameter_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_l1_cache_parameter_tb.vvp

dcache-lint:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -i -Wall \
		-s rv32_l1_data_cache \
		-o build/rv32_l1_data_cache_2005.vvp \
		rtl/rv32_l1_data_cache.v
	@$(TIMEOUT) 30 iverilog -g2012 -Wall \
		-s rv32_l1_data_cache \
		-o build/rv32_l1_data_cache_lint.vvp \
		$(FAKERAM) rtl/rv32_l1_data_cache.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1800-2012 -Wall \
		-Wno-TIMESCALEMOD -Wno-BLKSEQ \
		--top-module rv32_l1_data_cache $(FAKERAM) rtl/rv32_l1_data_cache.v
	@$(TIMEOUT) 120 yosys -q -p \
		'read_verilog -sv -D SYNTHESIS $(FAKERAM) rtl/rv32_l1_data_cache.v; hierarchy -check -top rv32_l1_data_cache; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check'

dcache-unit:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2012 -Wall \
		-s rv32_l1_data_cache_tb \
		-o build/rv32_l1_data_cache_tb.vvp \
		$(FAKERAM) rtl/rv32_l1_data_cache.v \
		tb/rv32_main_memory.v tb/rv32_l1_data_cache_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_l1_data_cache_tb.vvp
	@$(TIMEOUT) 30 iverilog -g2012 -I rtl \
		-s rv32_lsq_dcache_integration_tb \
		-o build/rv32_lsq_dcache_integration_tb.vvp \
		$(FAKERAM) rtl/rv32_load_store_queue.v rtl/rv32_l1_data_cache.v \
		tb/rv32_main_memory.v tb/rv32_lsq_dcache_integration_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_lsq_dcache_integration_tb.vvp

cache-bridge-lint:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -s rv32_l1_cache_axi_bridge \
		-o build/rv32_l1_cache_axi_bridge_2005.vvp \
		rtl/rv32_l1_cache_axi_bridge.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
		--top-module rv32_l1_cache_axi_bridge \
		rtl/rv32_l1_cache_axi_bridge.v
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog rtl/rv32_l1_cache_axi_bridge.v; hierarchy -check -top rv32_l1_cache_axi_bridge; proc; opt; select -assert-none t:$$dlatch; check'

cache-bridge-unit:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall \
		-s rv32_l1_cache_axi_bridge_tb \
		-o build/rv32_l1_cache_axi_bridge_tb.vvp \
		rtl/rv32_l1_cache_axi_bridge.v tb/rv32_l1_cache_axi_bridge_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_l1_cache_axi_bridge_tb.vvp
	@for seed in 1 7 42 101 1729 65537 1234567 2147483647; do \
		$(TIMEOUT) 30 iverilog -g2005 -Wall \
			-s rv32_l1_cache_axi_pipeline_tb \
			-P rv32_l1_cache_axi_pipeline_tb.SEED=$$seed \
			-o build/rv32_l1_cache_axi_pipeline_tb_$$seed.vvp \
			rtl/rv32_l1_cache_axi_bridge.v tb/rv32_l1_cache_axi_pipeline_tb.v || exit 1; \
		$(TIMEOUT) 30 vvp -N build/rv32_l1_cache_axi_pipeline_tb_$$seed.vvp || exit 1; \
	done

predictor-lint:
	@mkdir -p build
	@for width in 1 2 4; do \
		$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
			-P rv32_branch_predictor.FE_WIDTH=$$width \
			-P rv32_branch_predictor.BE_WIDTH=$$width \
			-s rv32_branch_predictor \
			-o build/rv32_branch_predictor_lint_$$width.vvp \
			rtl/rv32_branch_predictor.v || exit 1; \
		$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
			--top-module rv32_branch_predictor -Irtl \
			-GFE_WIDTH=$$width -GBE_WIDTH=$$width \
			rtl/rv32_branch_predictor.v || exit 1; \
		$(TIMEOUT) 120 yosys -q -p \
			'read_verilog -D SYNTHESIS -I rtl rtl/rv32_branch_predictor.v; chparam -set FE_WIDTH '"$$width"' -set BE_WIDTH '"$$width"' rv32_branch_predictor; hierarchy -check -top rv32_branch_predictor; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check' || exit 1; \
	done

predictor-unit:
	@mkdir -p build
	@for width in 1 2 4; do \
		$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
			-P rv32_branch_predictor_tb.FE_WIDTH=$$width \
			-P rv32_branch_predictor_tb.BE_WIDTH=$$width \
			-s rv32_branch_predictor_tb \
			-o build/rv32_branch_predictor_tb_$$width.vvp \
			rtl/rv32_branch_predictor.v \
			tb/rv32_branch_predictor_tb.v || exit 1; \
		$(TIMEOUT) 30 vvp -N \
			build/rv32_branch_predictor_tb_$$width.vvp || exit 1; \
	done
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_branch_predictor.FE_WIDTH=3 \
		-s rv32_branch_predictor \
		-o build/rv32_branch_predictor_bad_fe.vvp \
		rtl/rv32_branch_predictor.v
	@$(TIMEOUT) 30 vvp -N build/rv32_branch_predictor_bad_fe.vvp 2>&1 | \
		grep -q '^ERROR rv32_branch_predictor invalid FE_WIDTH='
	@echo "PASS branch predictor rejected invalid FE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_branch_predictor.BE_WIDTH=3 \
		-s rv32_branch_predictor \
		-o build/rv32_branch_predictor_bad_be.vvp \
		rtl/rv32_branch_predictor.v
	@$(TIMEOUT) 30 vvp -N build/rv32_branch_predictor_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_branch_predictor invalid BE_WIDTH='
	@echo "PASS branch predictor rejected invalid BE_WIDTH"
	@for violation in 1 2; do \
		$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
			-P rv32_branch_predictor_protocol_tb.VIOLATION=$$violation \
			-s rv32_branch_predictor_protocol_tb \
			-o build/rv32_branch_predictor_protocol_$$violation.vvp \
			rtl/rv32_branch_predictor.v \
			tb/rv32_branch_predictor_tb.v || exit 1; \
		if [ $$violation -eq 1 ]; then expected='non-control update'; \
		else expected='jump not taken'; fi; \
		$(TIMEOUT) 30 vvp -N \
			build/rv32_branch_predictor_protocol_$$violation.vvp 2>&1 | \
			grep -q "^ERROR rv32_branch_predictor $$expected" || exit 1; \
	done
	@echo "PASS branch predictor rejected protocol violations"

fetch-lint:
	@mkdir -p build
	@for fe_width in 1 2 4; do \
		for be_width in 1 2 4; do \
			$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
				-P rv32_fetch_pipeline.FE_WIDTH=$$fe_width \
				-P rv32_fetch_pipeline.BE_WIDTH=$$be_width \
				-s rv32_fetch_pipeline \
				-o build/rv32_fetch_pipeline_lint_$${fe_width}_$${be_width}.vvp \
				rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
				rtl/rv32_fetch_pipeline.v || exit 1; \
			$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 \
				-Wall --top-module rv32_fetch_pipeline -Irtl \
				-GFE_WIDTH=$$fe_width -GBE_WIDTH=$$be_width \
				rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
				rtl/rv32_fetch_pipeline.v || exit 1; \
			$(TIMEOUT) 120 yosys -q -p \
				'read_verilog -D SYNTHESIS -I rtl rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v rtl/rv32_fetch_pipeline.v; chparam -set FE_WIDTH '"$$fe_width"' -set BE_WIDTH '"$$be_width"' rv32_fetch_pipeline; hierarchy -check -top rv32_fetch_pipeline; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check' || exit 1; \
		done; \
	done

fetch-unit:
	@mkdir -p build
	@for fe_width in 1 2 4; do \
		for be_width in 1 2 4; do \
			$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
				-P rv32_fetch_pipeline_tb.FE_WIDTH=$$fe_width \
				-P rv32_fetch_pipeline_tb.BE_WIDTH=$$be_width \
				-s rv32_fetch_pipeline_tb \
				-o build/rv32_fetch_pipeline_tb_$${fe_width}_$${be_width}.vvp \
				rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
				rtl/rv32_fetch_pipeline.v \
				tb/rv32_fetch_pipeline_tb.v || exit 1; \
			$(TIMEOUT) 30 vvp -N \
				build/rv32_fetch_pipeline_tb_$${fe_width}_$${be_width}.vvp || exit 1; \
		done; \
	done
	@$(TIMEOUT) 30 iverilog -g2012 -Wall -I rtl \
		-s rv32_fetch_icache_integration_tb \
		-o build/rv32_fetch_icache_integration_tb.vvp \
		$(FAKERAM) \
		rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
		rtl/rv32_fetch_pipeline.v rtl/rv32_l1_instruction_cache.v \
		tb/rv32_main_memory.v tb/rv32_fetch_icache_integration_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_fetch_icache_integration_tb.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_fetch_pipeline.FE_WIDTH=3 \
		-s rv32_fetch_pipeline -o build/rv32_fetch_pipeline_bad_fe.vvp \
		rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
		rtl/rv32_fetch_pipeline.v
	@$(TIMEOUT) 30 vvp -N build/rv32_fetch_pipeline_bad_fe.vvp 2>&1 | \
		grep -q '^ERROR rv32_fetch_pipeline invalid FE_WIDTH='
	@echo "PASS fetch pipeline rejected invalid FE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_fetch_pipeline.BE_WIDTH=3 \
		-s rv32_fetch_pipeline -o build/rv32_fetch_pipeline_bad_be.vvp \
		rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
		rtl/rv32_fetch_pipeline.v
	@$(TIMEOUT) 30 vvp -N build/rv32_fetch_pipeline_bad_be.vvp 2>&1 | \
		grep -q '^ERROR rv32_fetch_pipeline invalid BE_WIDTH='
	@echo "PASS fetch pipeline rejected invalid BE_WIDTH"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_fetch_pipeline.FETCH_QUEUE_ENTRIES=6 \
		-P rv32_fetch_pipeline.FETCH_QUEUE_INDEX_WIDTH=3 \
		-s rv32_fetch_pipeline \
		-o build/rv32_fetch_pipeline_bad_entries.vvp \
		rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
		rtl/rv32_fetch_pipeline.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_fetch_pipeline_bad_entries.vvp 2>&1 | \
		grep -q '^ERROR rv32_fetch_pipeline invalid queue entries='
	@echo "PASS fetch pipeline rejected invalid queue entries"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_fetch_pipeline.FETCH_QUEUE_INDEX_WIDTH=4 \
		-s rv32_fetch_pipeline \
		-o build/rv32_fetch_pipeline_bad_index.vvp \
		rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
		rtl/rv32_fetch_pipeline.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_fetch_pipeline_bad_index.vvp 2>&1 | \
		grep -q '^ERROR rv32_fetch_pipeline queue index width='
	@echo "PASS fetch pipeline rejected invalid queue index width"
	@for violation in 1 2; do \
		$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
			-P rv32_fetch_pipeline_protocol_tb.VIOLATION=$$violation \
			-s rv32_fetch_pipeline_protocol_tb \
			-o build/rv32_fetch_pipeline_protocol_$$violation.vvp \
			rtl/rv32im_decoder.v rtl/rv32_branch_predictor.v \
			rtl/rv32_fetch_pipeline.v \
			tb/rv32_fetch_pipeline_tb.v || exit 1; \
		if [ $$violation -eq 1 ]; then expected='non-prefix ready'; \
		else expected='unaligned redirect'; fi; \
		$(TIMEOUT) 30 vvp -N \
			build/rv32_fetch_pipeline_protocol_$$violation.vvp 2>&1 | \
			grep -q "^ERROR rv32_fetch_pipeline $$expected" || exit 1; \
	done
	@echo "PASS fetch pipeline rejected protocol violations"

dispatch-lint:
	@mkdir -p build
	@for fe_width in 1 2 4; do \
		for be_width in 1 2 4; do \
			$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
				-P rv32_decode_rename_dispatch.FE_WIDTH=$$fe_width \
				-P rv32_decode_rename_dispatch.BE_WIDTH=$$be_width \
				-s rv32_decode_rename_dispatch \
				-o build/rv32_decode_rename_dispatch_lint_$${fe_width}_$${be_width}.vvp \
				rtl/rv32im_decoder.v rtl/rv32_rename_unit.v \
				rtl/rv32_physical_register_file.v \
				rtl/rv32_decode_rename_dispatch.v || exit 1; \
			$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 \
				-Wall --top-module rv32_decode_rename_dispatch -Irtl \
				-GFE_WIDTH=$$fe_width -GBE_WIDTH=$$be_width \
				rtl/rv32im_decoder.v rtl/rv32_rename_unit.v \
				rtl/rv32_physical_register_file.v \
				rtl/rv32_decode_rename_dispatch.v || exit 1; \
			$(TIMEOUT) 120 yosys -q -p \
				'read_verilog -D SYNTHESIS -I rtl rtl/rv32im_decoder.v rtl/rv32_rename_unit.v rtl/rv32_physical_register_file.v rtl/rv32_decode_rename_dispatch.v; chparam -set FE_WIDTH '"$$fe_width"' -set BE_WIDTH '"$$be_width"' rv32_decode_rename_dispatch; hierarchy -check -top rv32_decode_rename_dispatch; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check' || exit 1; \
		done; \
	done

dispatch-unit:
	@mkdir -p build
	@for fe_width in 1 2 4; do \
		for be_width in 1 2 4; do \
			$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
				-P rv32_decode_rename_dispatch_tb.FE_WIDTH=$$fe_width \
				-P rv32_decode_rename_dispatch_tb.BE_WIDTH=$$be_width \
				-s rv32_decode_rename_dispatch_tb \
				-o build/rv32_decode_rename_dispatch_tb_$${fe_width}_$${be_width}.vvp \
				rtl/rv32im_decoder.v rtl/rv32_rename_unit.v \
				rtl/rv32_physical_register_file.v \
				rtl/rv32_decode_rename_dispatch.v \
				tb/rv32_decode_rename_dispatch_tb.v || exit 1; \
			$(TIMEOUT) 30 vvp -N \
				build/rv32_decode_rename_dispatch_tb_$${fe_width}_$${be_width}.vvp || exit 1; \
		done; \
	done
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_dispatch_integration_tb \
		-o build/rv32_dispatch_integration_tb.vvp \
		rtl/rv32im_decoder.v rtl/rv32_rename_unit.v \
		rtl/rv32_physical_register_file.v \
		rtl/rv32_decode_rename_dispatch.v rtl/rv32_reorder_buffer.v \
		rtl/rv32_integer_reservation_station.v \
		rtl/rv32_memory_reservation_station.v \
		rtl/rv32_load_store_queue.v tb/rv32_dispatch_integration_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_dispatch_integration_tb.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-P rv32_decode_rename_dispatch.FE_WIDTH=3 \
		-s rv32_decode_rename_dispatch \
		-o build/rv32_decode_rename_dispatch_bad_fe.vvp \
		rtl/rv32im_decoder.v rtl/rv32_rename_unit.v \
		rtl/rv32_physical_register_file.v \
		rtl/rv32_decode_rename_dispatch.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_decode_rename_dispatch_bad_fe.vvp 2>&1 | \
		grep -q '^ERROR rv32_decode_rename_dispatch invalid parameters'
	@echo "PASS dispatch rejected invalid parameters"
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32_decode_rename_dispatch_protocol_tb \
		-o build/rv32_decode_rename_dispatch_protocol.vvp \
		rtl/rv32im_decoder.v rtl/rv32_rename_unit.v \
		rtl/rv32_physical_register_file.v \
		rtl/rv32_decode_rename_dispatch.v \
		tb/rv32_decode_rename_dispatch_tb.v
	@$(TIMEOUT) 30 vvp -N \
		build/rv32_decode_rename_dispatch_protocol.vvp 2>&1 | \
		grep -q '^ERROR rv32_decode_rename_dispatch non-prefix fetch valid'
	@echo "PASS dispatch rejected protocol violations"
