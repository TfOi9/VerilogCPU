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

lint unit smoke regression matrix perf synth report:
	@echo "Target '$@' is reserved for a later implementation stage." >&2
	@exit 2
