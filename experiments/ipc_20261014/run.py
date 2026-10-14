#!/usr/bin/env python3
"""Reuse the bounded three-program cache pilot with the pipelined LSQ observer."""

import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("cache_pilot", HERE.parent / "cache_20261014/run.py")
pilot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pilot)
pilot.EXP = HERE

if __name__ == "__main__":
    pilot.main()
