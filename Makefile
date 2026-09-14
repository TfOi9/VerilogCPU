SHELL := /bin/bash

.DEFAULT_GOAL := doctor

.PHONY: doctor lint unit memory-lint memory-unit main-memory-lint main-memory-unit icache-lint icache-unit dcache-lint dcache-unit smoke regression matrix perf synth report image image-test

PYTHON ?= python3
TIMEOUT ?= timeout
PROGRAM ?= tests/programs/accumulate.c
ARCH ?= rv32i
OUT_DIR ?= build/images/accumulate-$(ARCH)

doctor:
	@./tools/doctor.sh

image:
	@$(TIMEOUT) 120 $(PYTHON) tools/make_image.py $(PROGRAM) --arch $(ARCH) --out-dir $(OUT_DIR)

image-test:
	@$(TIMEOUT) 120 $(PYTHON) tools/test_image_pipeline.py

lint: memory-lint main-memory-lint icache-lint dcache-lint
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

unit: memory-unit main-memory-unit icache-unit dcache-unit
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

smoke regression matrix perf synth report:
	@echo "Target '$@' is reserved for a later implementation stage." >&2
	@exit 2

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
	@$(TIMEOUT) 30 iverilog -g2005 -Wall \
		-s rv32_l1_instruction_cache \
		-o build/rv32_l1_instruction_cache_lint.vvp \
		rtl/rv32_l1_instruction_cache.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		--top-module rv32_l1_instruction_cache \
		rtl/rv32_l1_instruction_cache.v
	@$(TIMEOUT) 120 yosys -q -p \
		'read_verilog -D SYNTHESIS rtl/rv32_l1_instruction_cache.v; hierarchy -check -top rv32_l1_instruction_cache; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check'

icache-unit:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall \
		-s rv32_l1_instruction_cache_tb \
		-o build/rv32_l1_instruction_cache_tb.vvp \
		rtl/rv32_l1_instruction_cache.v \
		tb/rv32_main_memory.v tb/rv32_l1_instruction_cache_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_l1_instruction_cache_tb.vvp

dcache-lint:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall \
		-s rv32_l1_data_cache \
		-o build/rv32_l1_data_cache_lint.vvp \
		rtl/rv32_l1_data_cache.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		--top-module rv32_l1_data_cache rtl/rv32_l1_data_cache.v
	@$(TIMEOUT) 120 yosys -q -p \
		'read_verilog -D SYNTHESIS rtl/rv32_l1_data_cache.v; hierarchy -check -top rv32_l1_data_cache; proc; memory; opt; select -assert-none t:$$dlatch t:$$div t:$$mod; check'

dcache-unit:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall \
		-s rv32_l1_data_cache_tb \
		-o build/rv32_l1_data_cache_tb.vvp \
		rtl/rv32_l1_data_cache.v \
		tb/rv32_main_memory.v tb/rv32_l1_data_cache_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_l1_data_cache_tb.vvp
	@$(TIMEOUT) 30 iverilog -g2005 -I rtl \
		-s rv32_lsq_dcache_integration_tb \
		-o build/rv32_lsq_dcache_integration_tb.vvp \
		rtl/rv32_load_store_queue.v rtl/rv32_l1_data_cache.v \
		tb/rv32_main_memory.v tb/rv32_lsq_dcache_integration_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32_lsq_dcache_integration_tb.vvp
