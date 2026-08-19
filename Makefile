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
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32im_decoder.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32i_alu.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32m_multiplier.v
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32m_divider.v
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32im_decoder.v; hierarchy -check -top rv32im_decoder; proc; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32i_alu.v; hierarchy -check -top rv32i_alu; proc; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32m_multiplier.v; hierarchy -check -top rv32m_multiplier; proc; opt; select -assert-none t:$$mul; check'
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32m_divider.v; hierarchy -check -top rv32m_divider; proc; opt; select -assert-none t:$$div t:$$mod t:$$divfloor t:$$modfloor; check'

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

smoke regression matrix perf synth report:
	@echo "Target '$@' is reserved for a later implementation stage." >&2
	@exit 2
