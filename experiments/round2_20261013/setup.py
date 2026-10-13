#!/usr/bin/env python3
"""Freeze production inputs and generate independent, disposable RTL variants."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXP = Path(__file__).resolve().parent
OUT = ROOT / 'build/round2-20261013'
VARIANTS = ('baseline', 'lsq-turnover', 'rs-ready-cut')
CONFIGS = ((2, 2, 64, 32), (1, 1, 48, 16), (4, 1, 96, 32), (4, 4, 64, 16))
BASELINE_HEAD = '4fa767cf09cdeebd1ced43973d53490acb6008a5'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('expected exactly one replacement: ' + old[:100])
    return text.replace(old, new)

def protected_files():
    paths = set(ROOT.glob('rtl/*'))
    for folder in ('tools', 'tb', 'verilog', 'experiments/performance_20261013'):
        paths.update(p for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
    paths.update(ROOT/p for p in ('Makefile', 'SPEC.md', 'SORA.md', 'PLAN.md', 'MODIFY.md'))
    sora = ROOT.parent/'SORA'
    paths.update(sora/p for p in subprocess.check_output(['git', '-C', str(sora), 'ls-files'], text=True).splitlines())
    return sorted(p for p in paths if p.is_file())

def verify():
    manifest = json.loads((OUT/'manifest.json').read_text())
    changed = [p for p, sha in manifest['protected_sha256'].items() if not Path(p).is_file() or digest(Path(p)) != sha]
    if changed:
        raise RuntimeError('protected files changed: ' + repr(changed))
    for variant, hashes in manifest['variants'].items():
        if any(not Path(p).is_file() or digest(Path(p)) != sha for p, sha in hashes.items()):
            raise RuntimeError('variant changed after snapshot: ' + variant)
    status = subprocess.check_output(['git', '-C', str(ROOT.parent/'SORA'), 'status', '--short'], text=True)
    if status != manifest['sora_status']:
        raise RuntimeError('SORA working tree status changed')
    return manifest

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if (OUT/'manifest.json').exists():
        verify()
        print('Existing snapshots verified; not overwritten.')
        return
    for path in list((ROOT/'rtl').glob('*'))+[ROOT/'verilog/filelist.f']:
        if path.is_file():
            original = subprocess.check_output(['git', 'show', BASELINE_HEAD+':'+str(path.relative_to(ROOT))], cwd=ROOT)
            if path.read_bytes() != original:
                raise RuntimeError('production RTL differs from the pinned baseline: '+str(path))
    manifest = {'head': BASELINE_HEAD,
                'checkout_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'initial_status': subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True),
                'sora_status': subprocess.check_output(['git', '-C', str(ROOT.parent/'SORA'), 'status', '--short'], text=True),
                'protected_sha256': {str(p): digest(p) for p in protected_files()}, 'variants': {}}
    names = [Path(s).name for s in (ROOT/'verilog/filelist.f').read_text().splitlines() if s.strip()]
    for variant in VARIANTS:
        dest = OUT/variant/'rtl'
        dest.mkdir(parents=True)
        for path in (ROOT/'rtl').iterdir():
            if path.is_file():
                (dest/path.name).write_bytes(path.read_bytes())
        if variant == 'lsq-turnover':
            path = dest/'rv32_load_store_queue.v'
            path.write_text(replace_once(path.read_text(), 'if (!request_valid && !inflight &&',
                'if (!request_valid &&\n                        (!inflight || (cache_response_valid_i && cache_response_ready_o)) &&'))
        if variant == 'rs-ready-cut':
            for name in ('rv32_integer_reservation_station.v', 'rv32_mdu_reservation_stations.v'):
                path = dest/name
                text, n = re.subn(r'if \(!entry_busy\[allocation_entry_index\] \|\|\s*issue_remove_mask_reg\[allocation_entry_index\]\)',
                                 'if (!entry_busy[allocation_entry_index])', path.read_text())
                assert n == 1
                path.write_text(text)
        filelist = dest.parent/'filelist.f'
        filelist.write_text('\n'.join(str(dest/n) for n in names) + '\n')
        manifest['variants'][variant] = {str(p): digest(p) for p in sorted(dest.iterdir())}
        tb = dest.parent/'tb'
        tb.mkdir()
        for path in (ROOT/'tb').glob('*'):
            if path.is_file():
                (tb/path.name).write_bytes(path.read_bytes())
        if variant == 'rs-ready-cut':
            path = tb/'rv32_integer_reservation_station_tb.v'
            path.write_text(replace_once(path.read_text(), 'check(dispatch_ready_o, 54);\n            clock_edge;',
                'check(!dispatch_ready_o, 54);\n            dispatch_fire_i = 1\'b0;\n            clock_edge;\n            issue_ready_i = 0;\n            broadcast_valid_i = 0;\n            #1;\n            check(occupancy_o == INT_RS_ENTRIES - BE_WIDTH, 154);\n            check(dispatch_ready_o, 155);\n            dispatch_fire_i = 1\'b1;\n            clock_edge;'))
            path = tb/'rv32_mdu_reservation_stations_tb.v'
            path.write_text(replace_once(path.read_text(), 'check(mul_dispatch_ready_o, 31);\n            mul_dispatch_fire_i = 1\'b1;',
                'check(!mul_dispatch_ready_o, 31);\n            mul_dispatch_fire_i = 1\'b0;\n            clock_edge;\n            mul_issue_grant = 1\'b0;\n            broadcast_valid_i = 0;\n            #1;\n            check(mul_occupancy_o == RS_ENTRIES - 1, 131);\n            check(mul_dispatch_ready_o, 132);\n            mul_dispatch_fire_i = 1\'b1;'))
            path.write_text(replace_once(path.read_text(), 'check(mul_occupancy_o == RS_ENTRIES, 32);',
                'check(mul_occupancy_o == RS_ENTRIES, 32);\n            mul_issue_grant = 1\'b1;'))
            vectors = replace_once((ROOT/'tools/generate_int_rs_vectors.py').read_text(),
                'if slot is None or index in issue_remove', 'if slot is None')
            (dest.parent/'generate_int_rs_vectors.py').write_text(vectors)
        unit_dir = dest.parent/'unit'
        unit_dir.mkdir()
        makefile = (ROOT/'Makefile').read_text().replace('build/', str(unit_dir)+'/').replace('mkdir -p build', 'mkdir -p '+str(unit_dir))
        makefile = makefile.replace('rtl/', str(dest)+'/').replace('-I rtl', '-I '+str(dest)).replace('-Irtl', '-I'+str(dest)).replace('tb/', str(tb)+'/')
        if variant == 'rs-ready-cut':
            makefile = makefile.replace('tools/generate_int_rs_vectors.py', str(dest.parent/'generate_int_rs_vectors.py'))
        (dest.parent/'Makefile.unit').write_text(makefile)
    (OUT/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    verify()
    print('Created three independent snapshots at ' + str(OUT))

if __name__ == '__main__':
    main()
