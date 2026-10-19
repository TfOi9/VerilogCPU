#!/usr/bin/env python3
"""Check Load-value coherence against an architectural reference and a bad-fill control."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from generate_core_vectors import immediate, register, store, execute

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORK = ROOT.parent/'RISC-V-CPU-2026'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'build/load-values')
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        out = out/('run-'+str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    inputs = list((ROOT/'rtl').glob('*.v'))+list((ROOT/'rtl').glob('*.vh'))
    inputs += [ROOT/'verilog/filelist.f', ROOT/'tools/build_configured.py',
               ROOT/'tools/generate_core_vectors.py', FRAMEWORK/'scripts/sim.cpp', Path(__file__)]
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in inputs}, 'cases': [], 'negative_rejections': []}

    def command(args, log, seconds):
        args = ['timeout', '-k', '5', str(seconds), *map(str, args)]
        log.with_suffix('.command.json').write_text(json.dumps(args, indent=2)+'\n')
        process = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
        log.write_text(process.stdout+process.stderr)
        return process

    def build(filelist, directory):
        log = directory.with_suffix('.build.log')
        p = command([sys.executable, '-B', ROOT/'tools/build_configured.py', '--framework', FRAMEWORK,
                     '--filelist', filelist, '--out', directory, '--fe-width', '4', '--be-width', '4',
                     '--phys-regs', '64', '--rob-entries', '32', '--jobs', '2'], log, 600)
        assert p.returncode == 0 and not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log
        return directory/'sim'

    try:
        sim = build(ROOT/'verilog/filelist.f', out/'positive')
        result['sim_sha256'] = digest(sim)
        for variant, before, after, size, offset in itertools.product(range(2), range(5), (8, 16, 24), (0, 1), (0, 1)):
            if size == 1 and offset % 2:
                continue
            words = [0x000100b7, 0x112233b7, immediate(7, 7, 0x344), store(7, 1, 0), immediate(5, 1, 0)]
            words += [immediate(5, 5, 0)]*24
            words += [immediate(8, 5, 0, 2, 0x03), immediate(9, 8, 255, 7),
                      immediate(9, 9, 1), immediate(10, 0, 1)]
            words += [register(11, 9, 10, 0, 1)] if variant == 0 else [immediate(11, 9, 0)]
            words += [immediate(14, 14, 1)]*before
            words += [store(11, 1, offset, size), immediate(12, 1, 2, 0, 0x03), immediate(5, 1, 0)]
            words += [immediate(5, 5, 0)]*after
            words += [immediate(10, 5, 0, 2, 0x03), 0x80000fb7, store(10, 31, 0)]
            trace, expected = execute(words)
            label = f'v{variant}-b{before}-a{after}-s{size}-o{offset}'
            image = out/(label+'.data')
            image.write_text('@00000000\n'+'\n'.join(
                ' '.join(f'{b:02x}' for b in w.to_bytes(4, 'little')) for w in words)+'\n')
            log = out/(label+'.log')
            p = command([sim, image, expected, '10000', '10'], log, 10)
            match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', p.stdout)
            assert p.returncode == 0 and match and int(match[2]) == int(match[3]) == expected, log
            result['cases'].append({'name': label, 'image': str(image), 'expected': expected,
                                    'instructions': len(trace), 'cycles': int(match[1]),
                                    'image_sha256': digest(image), 'log_sha256': digest(log)})
        assert len(result['cases']) == 90
        mutant = out/'partial-fill-source'
        for name in ('rtl', 'verilog'):
            shutil.copytree(ROOT/name, mutant/name)
        source = mutant/'rtl/rv32_load_store_queue.v'
        text = source.read_text()
        guard = 'pending_width[response_slot] == `RV32_MEMORY_WORD &&'
        assert text.count(guard) == 1
        source.write_text(text.replace(guard, ''))
        bad = build(mutant/'verilog/filelist.f', out/'negative')
        result['negative_sim_sha256'] = digest(bad)
        for case in result['cases']:
            log = out/(case['name']+'-negative.log')
            p = command([bad, case['image'], case['expected'], '10000', '10'], log, 10)
            if p.returncode:
                match = re.fullmatch(r'FAIL cycles=(\d+) result=(\d+) expected=(\d+)\s*', p.stdout)
                assert p.returncode == 1 and match and match[2] != match[3], log
                result['negative_rejections'].append({'name': case['name'], 'log_sha256': digest(log)})
        assert result['negative_rejections'], 'bad partial fills were not detected'
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS Load values', len(result['cases']), 'positive cases;',
          len(result['negative_rejections']), 'bad-fill rejections', out, flush=True)


if __name__ == '__main__':
    main()
