#!/usr/bin/env python3
"""Check multi-MSHR ownership, speculative errors and SRAM fetch buffering."""
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
    parser.add_argument('--waiters', type=int, choices=(2, 4), default=4)
    parser.add_argument('--out', type=Path, default=ROOT/'build/tier3-paths')
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        out = out/('run-'+str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    ram = ROOT.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'
    cache = ROOT/'rtl/rv32_l1_data_cache.v'
    bridge = ROOT/'rtl/rv32_l1_cache_axi_bridge.v'
    fetch = ROOT/'rtl/rv32_fetch_pipeline.v'
    decoder = ROOT/'rtl/rv32im_decoder.v'
    predictor = ROOT/'rtl/rv32_branch_predictor.v'
    inputs = [ram, cache, bridge, fetch, decoder, predictor, Path(__file__)]
    inputs += [ROOT/'tb'/n for n in ('rv32_cache_multi_mshr_tb.v',
               'rv32_l1_cache_wide_bridge_tb.v', 'rv32_fetch_sram_buffer_tb.v')]
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in inputs}, 'tests': []}

    def test(top, label, parameters, sources, rejection=None):
        if top == 'rv32_cache_multi_mshr_tb':
            parameters = dict(parameters, WAITERS=args.waiters)
        options = [v for k, n in parameters.items() for v in ('-P', top+'.'+k+'='+str(n))]
        commands = [['iverilog', '-g2012' if ram in sources else '-g2005', '-I', ROOT/'rtl',
                     '-s', top, *options, '-o', out/label, *sources, ROOT/'tb'/(top+'.v')],
                    ['vvp', '-N', out/label]]
        logs = {}
        for phase, command in zip(('build', 'run'), commands):
            command = ['timeout', '-k', '5', '45', *map(str, command)]
            process = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            log = out/(label+'-'+phase+'.log')
            log.write_text(process.stdout+process.stderr)
            log.with_suffix('.command.json').write_text(json.dumps(command, indent=2)+'\n')
            logs[str(log)] = digest(log)
            if rejection and phase == 'run':
                assert process.returncode != 0 and rejection in log.read_text(), log
            else:
                assert process.returncode == 0 and not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log
        if not rejection:
            assert 'PASS ' in log.read_text(), log
        counts = {k: int(n) for k, n in re.findall(
            r'(checks|responses|merges|dual|both_ready|join_pop|errors|pf_reads|joins|empty|read_max)=(\d+)', log.read_text())}
        result['tests'].append({'name': label, 'passed': True, 'parameters': parameters,
                                'expected_rejection': rejection, 'counts': counts, 'log_sha256': logs})
        if len(result['tests']) % 25 == 0 or rejection:
            print('PASS paths', len(result['tests']), label, flush=True)

    try:
        for mshrs, ways, late, latency, seed in itertools.product((2, 4), (1, 2, 3, 4), (0, 1), (1, 7, 31), (1, 2, 42)):
            label = f'cache-m{mshrs}-w{ways}-c{late}-l{latency}-s{seed}'
            test('rv32_cache_multi_mshr_tb', label,
                 {'MSHRS': mshrs, 'SETS': 8, 'WAYS': ways, 'LATE_CONFIRM': late,
                  'LATENCY': latency, 'SEED': seed}, [ram, cache])
        for mshrs, ways, distance, latency, seed in itertools.product((2, 4), (1, 2, 4), (1, 4), (7, 31), (1, 2, 42)):
            label = f'prefetch-m{mshrs}-w{ways}-d{distance}-l{latency}-s{seed}'
            test('rv32_cache_multi_mshr_tb', label,
                 {'MSHRS': mshrs, 'SETS': 8, 'WAYS': ways, 'PREFETCH': 1,
                  'DISTANCE': distance, 'LATENCY': latency, 'SEED': seed}, [ram, cache])
        for seed in (1, 2, 7, 42, 101, 1729, 65537, 1234567):
            test('rv32_l1_cache_wide_bridge_tb', 'wide-bridge-'+str(seed), {'SEED': seed}, [bridge])
        for fe, be, entries, sram in itertools.product((1, 2, 4), (1, 2, 4), (1, 4, 16, 64), (0, 1)):
            test('rv32_fetch_sram_buffer_tb', f'fetch-f{fe}-b{be}-e{entries}-s{sram}',
                 {'FE_WIDTH': fe, 'BE_WIDTH': be, 'LINE_BUFFER_ENTRIES': entries, 'USE_SRAM': sram},
                 [ram, decoder, predictor, fetch])
        test('rv32_cache_multi_mshr_tb', 'reject-unowned-wide-memory-id',
             {'BAD_ID': 1, 'MSHRS': 4, 'SETS': 8}, [ram, cache],
             'ERROR rv32_l1_data_cache unknown or duplicate memory response')
        mutant = out/'unsolicited-prefetch.v'
        text = cache.read_text()
        old = '(m_delivery && m_count[m_delivery_slot] != 0)'
        assert text.count(old) == 1
        mutant.write_text(text.replace(old, 'm_delivery'))
        test('rv32_cache_multi_mshr_tb', 'reject-unsolicited-prefetch',
             {'MSHRS': 4, 'SETS': 8, 'PREFETCH': 1}, [ram, mutant], 'duplicate or unknown ID')
        mutant = out/'truncated-bridge-id.v'
        text, count = re.subn(r'assign d_response_id_o = D_TAGGED != 0.*?;',
                             "assign d_response_id_o = 1'b0;", bridge.read_text(), flags=re.S)
        assert count == 1
        mutant.write_text(text)
        test('rv32_l1_cache_wide_bridge_tb', 'reject-truncated-wide-id', {}, [mutant],
             'D read response identity or data')
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS tier3 paths', len(result['tests']), 'configurations', out, flush=True)


if __name__ == '__main__':
    main()
