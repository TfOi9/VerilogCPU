#!/usr/bin/env python3
"""Freeze RTL with one explicit store hint parameter override for official builds."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--store-hints', type=int, choices=(1,4,8,16), required=True)
    args = parser.parse_args()
    source = args.source.resolve();out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    originals = list((source/'rtl').glob('*')) + [source/'verilog/filelist.f']
    hashes = {str(p):digest(p) for p in originals if p.is_file()}
    shutil.copytree(source/'rtl', out/'rtl')
    shutil.copytree(source/'verilog', out/'verilog')
    top = out/'rtl/student_top.v'
    text,n = re.subn(r'(parameter STORE_HINTS = )\d+',
                    lambda m:m[1]+str(args.store_hints),top.read_text())
    assert n == 1
    top.write_text(text)
    assert all(digest(Path(p)) == h for p,h in hashes.items())
    projected = list((out/'rtl').glob('*')) + [out/'verilog/filelist.f']
    record = {'source_sha256':hashes,'store_hints':args.store_hints,
              'projected_sha256':{str(p):digest(p) for p in projected if p.is_file()}}
    (out/'projection.json').write_text(json.dumps(record,indent=2)+'\n')
    print(out)


if __name__ == '__main__':
    main()
