SHELL := /bin/bash

.DEFAULT_GOAL := doctor

.PHONY: doctor lint unit smoke regression matrix perf synth report image image-test

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

lint:
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

unit:
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

smoke regression matrix perf synth report:
	@echo "Target '$@' is reserved for a later implementation stage." >&2
	@exit 2
