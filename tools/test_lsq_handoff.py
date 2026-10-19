#!/usr/bin/env python3
"""Qualify Load handoff, Store progress and response ownership."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'build/lsq-handoff-unit')
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        out = out / ('run-' + str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    rtl = ROOT / 'rtl/rv32_load_store_queue.v'
    tb = ROOT / 'tb/rv32_lsq_handoff_tb.v'
    inputs = [rtl, tb, Path(__file__), ROOT / 'rtl/rv32im_defs.vh']
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in inputs}, 'tests': []}

    def test(be, lsq, rob, fast, tagged, source=rtl, rejection=None):
        label = f'be{be}-lsq{lsq}-rob{rob}-f{fast}-t{tagged}'
        if rejection:
            label = 'negative-' + label
        top = 'rv32_lsq_handoff_tb'
        parameters = dict(BE_WIDTH=be, LSQ_ENTRIES=lsq, LSQ_INDEX_WIDTH=(lsq-1).bit_length(),
                          ROB_ENTRIES=rob, ROB_INDEX_WIDTH=(rob-1).bit_length(),
                          FAST_MODE=fast, TAGGED_MODE=tagged)
        options = [s for k, v in parameters.items() for s in ('-P', f'{top}.{k}={v}')]
        binary = out / label
        commands = [['iverilog', '-g2005', '-I', ROOT / 'rtl', '-s', top, *options,
                     '-o', binary, source, tb], ['vvp', '-N', binary]]
        logs = {}
        for phase, command in zip(('build', 'run'), commands):
            command = ['timeout', '-k', '5', '30', *map(str, command)]
            run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            log = out / (label + '-' + phase + '.log')
            log.write_text(run.stdout + run.stderr)
            log.with_suffix('.command.json').write_text(json.dumps(command, indent=2) + '\n')
            logs[str(log)] = digest(log)
            if rejection and phase == 'run':
                assert run.returncode != 0 and rejection in log.read_text(), log
            else:
                assert run.returncode == 0 and not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log
        if not rejection:
            assert 'PASS LSQ handoff' in log.read_text(), log
        result['tests'].append({'name': label, 'passed': True, 'parameters': parameters,
                                'expected_rejection': rejection, 'logs': logs})
        print('PASS', label, flush=True)

    try:
        for be, lsq, fast, tagged in itertools.product((1, 2, 4), (8, 16), (0, 1), (0, 1)):
            test(be, lsq, 32, fast, tagged)
        for be, lsq, rob in itertools.product((2, 4), (8, 16), (16, 64)):
            test(be, lsq, rob, 1, 1)
        reference = out / 'main-lsq.v'
        revision = '88362c8bafbe5c645a77757dcfa64e9e57d82510'
        reference.write_bytes(subprocess.check_output(
            ['git', 'show', revision + ':rtl/rv32_load_store_queue.v'], cwd=ROOT))
        test(2, 8, 32, 1, 1, reference, 'incoming load issues before edge')
        test(2, 8, 32, 0, 1, reference, 'store acknowledgment overlaps completion')
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
