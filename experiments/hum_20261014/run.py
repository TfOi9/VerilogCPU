#!/usr/bin/env python3
"""Run frozen memory-parallelism ablations against the same Cache geometry."""
import importlib.util
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('deep', ROOT/'experiments/deep_20261014/run.py')
deep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deep)
deep.VARIANTS = {
    'legacy': ((1024,1,16384,2), {'NONBLOCKING_DCACHE':0,'PARALLEL_BRIDGE':0,'HIT_UNDER_MISS':0}, {}),
    'bridge': ((1024,1,16384,2), {'NONBLOCKING_DCACHE':0,'PARALLEL_BRIDGE':1,'HIT_UNDER_MISS':0}, {}),
    'overlap': ((1024,1,16384,2), {'NONBLOCKING_DCACHE':1,'PARALLEL_BRIDGE':1,'HIT_UNDER_MISS':0}, {}),
    'hum': ((1024,1,16384,2), {'NONBLOCKING_DCACHE':1,'PARALLEL_BRIDGE':1,'HIT_UNDER_MISS':1}, {}),
}
if __name__ == '__main__':
    deep.main()
