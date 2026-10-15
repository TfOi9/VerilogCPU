#!/usr/bin/env python3
"""Qualify two MSHRs, merged ordering, tagged bridge errors and SRAM stalls."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'build/mshr-unit')
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        out = out/('run-'+str(time.time_ns()))
    out.mkdir(parents=True, exist_ok=False)
    ram = ROOT.parent/'RISC-V-CPU-2026/scripts/ram/sram_fakeram.sv'
    cache = ROOT/'rtl/rv32_l1_data_cache.v'
    bridge = ROOT/'rtl/rv32_l1_cache_axi_bridge.v'
    inputs = [ram, cache, bridge, Path(__file__), ROOT/'tb/rv32_cache_mshr_tb.v',
              ROOT/'tb/rv32_l1_cache_mshr_bridge_tb.v']
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    result = {'completed': False, 'passed': False,
              'source_sha256': {str(p): digest(p) for p in inputs}, 'tests': []}

    def test(top, label, parameters, sources, rejection=None):
        options = [v for k, n in parameters.items() for v in ('-P', top+'.'+k+'='+str(n))]
        commands = [['iverilog', '-g2012' if ram in sources else '-g2005', '-s', top,
                     *options, '-o', out/label, *sources, ROOT/'tb'/(top+'.v')],
                    ['vvp', '-N', out/label]]
        logs = {}
        for phase, command in zip(('build', 'run'), commands):
            command = ['timeout', '-k', '5', '45', *map(str, command)]
            run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            log = out/(label+'-'+phase+'.log')
            log.write_text(run.stdout+run.stderr)
            (out/(label+'-'+phase+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
            logs[str(log)] = digest(log)
            if rejection and phase == 'run':
                assert run.returncode == 1 and rejection in log.read_text(), log
            else:
                assert run.returncode == 0 and not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', log.read_text()), log
        if not rejection:
            assert 'PASS ' in log.read_text(), log
        counts = {k: int(n) for k, n in re.findall(r'(checks|responses|merges|dual|both_ready|join_pop|errors)=(\d+)', log.read_text())}
        result['tests'].append({'name': label, 'passed': True, 'parameters': parameters,
                                'expected_rejection': rejection, 'counts': counts, 'log_sha256': logs})
        print('PASS', label, counts, flush=True)

    try:
        for ways in (1, 2, 3, 4):
            for late in (0, 1):
                for latency in (1, 7, 31):
                    for seed in (1, 2, 42):
                        test('rv32_cache_mshr_tb', f'cache-{ways}-{late}-{latency}-{seed}',
                             {'WAYS': ways, 'LATE_CONFIRM': late, 'LATENCY': latency, 'SEED': seed}, [ram, cache])
        for ways in (1, 2, 3, 4):
            for directory in (1, 2, 8, 128):
                test('rv32_cache_mshr_tb', f'directory-{ways}-{directory}',
                     {'WAYS': ways, 'DIRECTORY': directory, 'LATE_CONFIRM': 1,
                      'AUX': 1, 'LATENCY': 7, 'SEED': 7}, [ram, cache])
        for seed in (1, 2, 7, 42, 101, 1729, 65537, 1234567):
            test('rv32_l1_cache_mshr_bridge_tb', 'bridge-'+str(seed), {'SEED': seed}, [bridge])
        test('rv32_cache_mshr_tb', 'reject-unowned-memory-id', {'BAD_ID': 1}, [ram, cache],
             'ERROR rv32_l1_data_cache unknown or duplicate memory response')
        mutant = out/'untagged_bridge.v'
        text, count = re.subn(r'assign d_response_id_o = D_TAGGED != 0.*?;',
                             "assign d_response_id_o = 1'b0;", bridge.read_text(), flags=re.S)
        assert count == 1
        mutant.write_text(text)
        test('rv32_l1_cache_mshr_bridge_tb', 'reject-lost-bridge-id', {}, [mutant],
             'D read response identity or data')
        mutant = out/'disabled_read_cache.v'
        text, count = re.subn(r'MSHR_ENTRIES == 2 \? !refill_install : \(pipeline_run',
                             '(pipeline_run', cache.read_text())
        assert count == 1
        mutant.write_text(text)
        test('rv32_cache_mshr_tb', 'reject-disabled-s1-read', {}, [ram, mutant],
             'ERROR rv32_l1_data_cache proven Store entered an MSHR')
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        (out/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS MSHR', len(result['tests']), 'configurations', out, flush=True)


if __name__ == '__main__':
    main()
