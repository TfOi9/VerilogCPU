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
	@$(TIMEOUT) 30 verilator --lint-only --language 1364-2005 -Wall \
		-Irtl rtl/rv32im_decoder.v
	@$(TIMEOUT) 30 yosys -q -p \
		'read_verilog -I rtl rtl/rv32im_decoder.v; hierarchy -check -top rv32im_decoder; proc; check'

unit:
	@mkdir -p build
	@$(TIMEOUT) 30 iverilog -g2005 -Wall -I rtl \
		-s rv32im_decoder_tb -o build/rv32im_decoder_tb.vvp \
		rtl/rv32im_decoder.v tb/rv32im_decoder_tb.v
	@$(TIMEOUT) 30 vvp -N build/rv32im_decoder_tb.vvp

smoke regression matrix perf synth report:
	@echo "Target '$@' is reserved for a later implementation stage." >&2
	@exit 2
