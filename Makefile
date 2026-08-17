SHELL := /bin/bash

.DEFAULT_GOAL := doctor

.PHONY: doctor lint unit smoke regression matrix perf synth report

doctor:
	@./tools/doctor.sh

lint unit smoke regression matrix perf synth report:
	@echo "Target '$@' is reserved for a later implementation stage." >&2
	@exit 2
