#!/usr/bin/env python3
"""Prove lazy PRF reset using actual RTL and observable logical state."""
import argparse
import json
from pathlib import Path
import re
import shutil

from measure import ROOT, run, save, digest


def instrument(source, module, lazy):
    text = source.read_text().replace('module rv32_physical_register_file #(', 'module ' + module + ' #(')
    text, count = re.subn(r'(write_data_i)\n\);',
                         r'\1,\n    output wire [(PHYS_REGS*32)-1:0] proof_state\n);', text)
    assert count == 1
    text = re.sub(r'\bregisters\b', module + '_data', text)
    value = module + '_data[index]'
    if lazy:
        value = 'initialized[index] ? ' + value + " : 32'd0"
    observation = '''
    genvar index;
    generate
        for (index = 0; index < PHYS_REGS; index = index + 1) begin : logical_state
            if (index == 0) begin : zero
                assign proof_state[index*32 +: 32] = 32'd0;
            end else begin : data
                assign proof_state[index*32 +: 32] = VALUE;
            end
        end
    endgenerate
'''.replace('VALUE', value)
    return text.replace('endmodule', observation + '\nendmodule')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--wide', action='store_true', help='also attempt the larger 96x4 proof')
    parser.add_argument('--reuse', type=Path, help='reuse individually proven identical models')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    old = ROOT / 'build/area-codex-20261018/baseline/rtl/rv32_physical_register_file.v'
    new = ROOT / 'rtl/rv32_physical_register_file.v'
    result = {'completed': False, 'passed': False,
              'sha256': {str(p): digest(p) for p in (old, new, Path(__file__))}, 'tests': []}
    result['yosys_sha256'] = digest(ROOT / '.deps/yosys/bin/yosys')
    try:
        configurations = [(33, 1), (56, 2)]
        if args.wide:
            configurations.append((96, 4))
        for count, lanes in configurations:
            name = f'p{count}-b{lanes}'
            source = out / (name + '.v')
            source.write_text(instrument(old, 'gold', False) + instrument(new, 'gate', True))
            script = out / (name + '.ys')
            script.write_text(f'read_verilog {source}\n'
                              f'chparam -set PHYS_REGS {count} -set PHYS_REG_ADDR_WIDTH {(count-1).bit_length()} '
                              f'-set BE_WIDTH {lanes} gold gate\n'
                              'proc\nmemory_map\nopt\nequiv_make gold gate equiv\n'
                              'hierarchy -top equiv\nequiv_induct -seq 2\nequiv_simple -seq 1\n'
                              'equiv_status -assert\n')
            log = out / (name + '.log')
            reused = None
            if args.reuse:
                previous = args.reuse.resolve()
                metadata = json.loads((previous / 'results.json').read_text())
                entry = next((row for row in metadata['tests'] if row['name'] == name), None)
                same_rtl = (previous / source.name).read_bytes() == source.read_bytes()
                same_script = (previous / script.name).read_text().replace(
                    str(previous / source.name), str(source)) == script.read_text()
                same_inputs = all(metadata['sha256'][str(p)] == digest(p) for p in (old, new))
                if entry and entry['passed'] and same_rtl and same_script and same_inputs:
                    previous_log = previous / log.name
                    assert digest(previous_log) == entry['log_sha256']
                    assert 'Equivalence successfully proven!' in previous_log.read_text()
                    shutil.copyfile(previous_log, log)
                    reused = str(previous_log)
            if reused is None:
                run([ROOT / '.deps/yosys/bin/yosys', '-Q', '-T', '-s', script], log, 120)
            assert 'Equivalence successfully proven!' in log.read_text()
            result['tests'].append({'name': name, 'passed': True, 'log_sha256': digest(log),
                                    'source_sha256': digest(source), 'reused_from': reused})
            print('PASS', name, flush=True)
        assert all(digest(Path(p)) == h for p, h in result['sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
