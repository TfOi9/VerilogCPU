#!/usr/bin/env python3
"""Exercise lock preservation, ties, padding and sparse outputs across selectors."""
import json
from stage import ROOT, EXP, OUT, stage, digest
from repair import execute

if __name__ == '__main__':
    stage()
    dest = OUT/'selector-tests'
    dest.mkdir(exist_ok=True)
    results = []
    for entries in (1, 3, 4, 6, 7, 8, 16):
        for ports in (1, 2, 4):
            name = f'e{entries}-p{ports}'
            binary = dest/(name+'.vvp')
            execute(['iverilog', '-g2005', '-s', 'ranked_select_tb',
                     '-P', 'ranked_select_tb.ENTRIES='+str(entries),
                     '-P', 'ranked_select_tb.PORTS='+str(ports),
                     '-P', 'ranked_select_tb.SLOT_WIDTH='+str(max(1, (entries-1).bit_length())),
                     '-o', binary, EXP/'rv32_ranked_select.v', EXP/'ranked_select_tb.v'], dest/(name+'-compile.log'), 30)
            result = execute(['vvp', '-N', binary], dest/(name+'.log'), 60)
            text = (dest/(name+'.log')).read_text()
            if 'PASS ranked_select' not in text or 'FAIL' in text:
                raise ValueError('selector comparison failed')
            result.update(passed=True, entries=entries, ports=ports, trials=1000)
            results.append(result)
    record = {'passed': True, 'results': results,
              'source_sha256': {str(p): digest(p) for p in (EXP/'rv32_ranked_select.v', EXP/'ranked_select_tb.v')}}
    (dest/'results.json').write_text(json.dumps(record, indent=2)+'\n')
    print('Passed 21000 randomized selector transactions across 21 parameter cases')
