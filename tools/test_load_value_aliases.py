#!/usr/bin/env python3
"""Exercise hashed Load-value tags and partial Stores with an architectural oracle."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    root = args.source_root.resolve()
    framework = root.parent/'RISC-V-CPU-2026'
    out = (args.out or root/'build/load-value-aliases').resolve()
    if out.exists():
        out = out/('run-'+str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(root/'tools'))
    from generate_core_vectors import immediate, store, execute
    inputs = list((root/'rtl').glob('*.v'))+list((root/'rtl').glob('*.vh'))
    inputs += [root/'verilog/filelist.f', root/'tools/build_configured.py',
               root/'tools/generate_core_vectors.py', framework/'scripts/sim.cpp', Path(__file__)]
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in inputs},
              'cases': [], 'negative_rejections': []}

    def command(args, log, seconds):
        args = ['timeout', '-k', '5', str(seconds), *map(str, args)]
        log.with_suffix('.command.json').write_text(json.dumps(args, indent=2)+'\n')
        process = subprocess.run(args, cwd=root, capture_output=True, text=True)
        log.write_text(process.stdout+process.stderr)
        return process

    def build(source, directory):
        log = directory.with_suffix('.build.log')
        process = command([sys.executable, '-B', root/'tools/build_configured.py',
                           '--framework', framework, '--filelist', source/'verilog/filelist.f',
                           '--out', directory, '--fe-width', '4', '--be-width', '4',
                           '--phys-regs', '64', '--rob-entries', '32', '--jobs', '2'], log, 600)
        assert process.returncode == 0 and not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log
        return directory/'sim'

    try:
        sim = build(root, out/'positive')
        result['sim_sha256'] = digest(sim)
        offsets = [0, 4, 8, 252, 256, 260, 264, 508, 512, 516, 768, 772, 1024, 1028, 1536, 2044]
        for seed in range(12):
            order = offsets.copy()
            random.Random(seed).shuffle(order)
            words = [0x000100b7, 0x112233b7, immediate(7, 7, 0x344), immediate(10, 0, 0)]
            for offset in offsets:
                words += [store(7, 1, offset), immediate(7, 7, 17)]
            words += [immediate(15, 15, 1)]*24
            for offset in order:
                words += [immediate(11, 1, offset, 2, 0x03), (11 << 20) | (10 << 15) | (10 << 7) | 0x33]
            for index, offset in enumerate(order):
                size = index % 2
                lane = index % 4 if size == 0 else (index % 2)*2
                words += [immediate(7, 0, 17+index), store(7, 1, offset+lane, size)]
                words += [immediate(15, 15, 1)]*(seed % 4+8)
                words += [immediate(11, 1, offset, 2, 0x03), (11 << 20) | (10 << 15) | (10 << 7) | 0x33]
            words += [0x80000fb7, store(10, 31, 0)]
            trace, expected = execute(words)
            image = out/(str(seed)+'.data')
            image.write_text('@00000000\n'+'\n'.join(
                ' '.join(f'{b:02x}' for b in word.to_bytes(4, 'little')) for word in words)+'\n')
            log = out/(str(seed)+'.log')
            process = command([sim, image, expected, 20000, 10], log, 15)
            match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', process.stdout)
            assert process.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, log
            result['cases'].append({'seed': seed, 'image': str(image), 'image_sha256': digest(image),
                                    'expected': expected, 'instructions': len(trace),
                                    'cycles': int(match[1]), 'log_sha256': digest(log)})
        mutant = out/'bad-tag-source'
        for name in ('rtl', 'verilog'):
            shutil.copytree(root/name, mutant/name)
        path = mutant/'rtl/rv32_load_store_queue.v'
        text = path.read_text()
        needle = 'lv_lookup_tag == load_address_i[LOAD_VALUE_TAG_HIGH:LOAD_VALUE_TAG_LOW]'
        assert text.count(needle) == 1
        path.write_text(text.replace(needle,
            '(lv_lookup_tag >> 1) == (load_address_i >> (LOAD_VALUE_TAG_LOW + 1))'))
        bad = build(mutant, out/'negative')
        result['negative_sim_sha256'] = digest(bad)
        for case in result['cases']:
            log = out/(str(case['seed'])+'-negative.log')
            process = command([bad, case['image'], case['expected'], 20000, 10], log, 15)
            if process.returncode:
                match = re.fullmatch(r'FAIL cycles=(\d+) result=(\d+) expected=(\d+)\s*', process.stdout)
                assert process.returncode == 1 and match and match[2] != match[3], log
                result['negative_rejections'].append({'seed': case['seed'], 'log_sha256': digest(log)})
        assert len(result['cases']) == 12 and result['negative_rejections']
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS Load aliases', len(result['cases']), 'positive cases;',
          len(result['negative_rejections']), 'bad-tag rejections', out, flush=True)


if __name__ == '__main__':
    main()
