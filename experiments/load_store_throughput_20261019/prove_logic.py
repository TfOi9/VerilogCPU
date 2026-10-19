#!/usr/bin/env python3
"""Prove issue grants or PRF reads against the main baseline."""
import argparse
import subprocess
from pathlib import Path
from measure import ROOT, digest, run, save

BASE = '88362c8bafbe5c645a77757dcfa64e9e57d82510'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', choices=('issue', 'prf'), required=True)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    module = 'rv32_issue_arbiter' if args.kind == 'issue' else 'rv32_physical_register_file'
    candidate = args.source / 'rtl' / (module + '.v')
    original = subprocess.check_output(['git', 'show', BASE + ':rtl/' + module + '.v'], cwd=ROOT).decode()
    reference = out / 'reference.v'
    reference.write_text(original)
    yosys = ROOT / '.deps/yosys/bin/yosys'
    abc = ROOT / '.deps/yosys/bin/yosys-abc'
    inputs = [candidate, reference, Path(__file__), yosys, abc]
    result = {'completed': False, 'passed': False, 'reference_revision': BASE,
              'source_sha256': {str(p): digest(p) for p in inputs}, 'tests': []}
    try:
        if args.kind == 'issue':
            for be in (1, 2, 4):
                for rob in (16, 32, 64):
                    label = f'be{be}-r{rob}'
                    bits = (rob-1).bit_length()
                    for name, source in (('reference', reference), ('candidate', candidate)):
                        script = out / (label + '-' + name + '.ys')
                        script.write_text(f'read_verilog {source}\n'
                                          f'chparam -set BE_WIDTH {be} -set ROB_ENTRIES {rob} '
                                          f'-set ROB_INDEX_WIDTH {bits} -set ROB_TAG_WIDTH {bits+2} {module}\n'
                                          f'hierarchy -top {module}\nproc\nflatten\nopt\ntechmap\nopt\naigmap\n'
                                          f'write_aiger {out / (label + "-" + name + ".aig")}\n')
                        run([yosys, '-Q', '-T', '-s', script], script.with_suffix('.log'), 60)
                    log = out / (label + '-cec.log')
                    run([abc, '-c', f'cec {out / (label + "-reference.aig")} '
                                   f'{out / (label + "-candidate.aig")}'], log, 180)
                    assert 'Networks are equivalent.' in log.read_text(), log
                    result['tests'].append({'name': label, 'passed': True, 'log_sha256': digest(log)})
                    print('PASS', label, flush=True)
        else:
            gold = out / 'gold.v'
            gate = out / 'gate.v'
            gold.write_text(original.replace('module ' + module + ' #(', 'module gold #(', 1))
            gate.write_text(candidate.read_text().replace('module ' + module + ' #(', 'module gate #(', 1))
            for be in (1, 2, 4):
                label = f'be{be}-p56'
                script = out / (label + '.ys')
                script.write_text(f'read_verilog {gold} {gate}\n'
                                  f'chparam -set BE_WIDTH {be} -set PHYS_REGS 56 -set PHYS_REG_ADDR_WIDTH 6 gold\n'
                                  f'chparam -set BE_WIDTH {be} -set PHYS_REGS 56 -set PHYS_REG_ADDR_WIDTH 6 gate\n'
                                  'proc\nmemory_map\nopt\nequiv_make gold gate equiv\n'
                                  'hierarchy -top equiv\nequiv_simple -undef\nequiv_induct -seq 3\n'
                                  'equiv_status -assert\n')
                log = out / (label + '.log')
                run([yosys, '-Q', '-T', '-s', script], log, 600)
                assert 'Equivalence successfully proven!' in log.read_text(), log
                result['tests'].append({'name': label, 'passed': True, 'log_sha256': digest(log)})
                print('PASS', label, flush=True)
        assert all(digest(Path(p)) == h for p, h in result['source_sha256'].items())
        result.update(completed=True, passed=True)
    finally:
        save(out / 'results.json', result)


if __name__ == '__main__':
    main()
