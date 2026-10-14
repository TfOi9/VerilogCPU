#!/usr/bin/env python3
"""Qualify a frozen official simulator without expensive per-cycle profiling."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT.parent / 'RISC-V-CPU-2026-Testcases'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    sim = args.sim.resolve(); source = args.source.resolve(); out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    cases = sorted(CASES.glob('correctness_*')) + sorted(CASES.glob('perf_*'))
    dependencies = [sim, Path(__file__), source/'verilog/filelist.f']
    dependencies += list((source/'rtl').glob('*'))
    dependencies += [p/name for p in cases for name in ('program.data','expected.txt','metrics.json')]
    hashes = {str(p): digest(p) for p in dependencies if p.is_file()}
    report = {'completed': False, 'passed': False, 'source_sha256': hashes,
              'latency': 10, 'max_cycles': 30000000, 'results': []}
    record = out/'results.json'
    def save():
        record.write_text(json.dumps(report, indent=2) + '\n')
    try:
        for case in cases:
            expected = int((case/'expected.txt').read_text())
            limit = 600 if case.name == 'correctness_pi' else 120
            command = ['timeout','-k','5',str(limit),str(sim),str(case/'program.data'),
                       str(expected),'30000000','10']
            started = time.monotonic()
            process = subprocess.run(command, text=True, capture_output=True)
            log = out/(case.name+'.log');log.write_text(process.stdout+process.stderr)
            (out/(case.name+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
            match = re.fullmatch(r'PASS cycles=(\d+) result=(\d+) expected=(\d+)\s*', process.stdout)
            passed = bool(process.returncode == 0 and match and int(match[2]) == int(match[3]) == expected
                          and not re.search(r'(?m)^(ERROR|FAIL|%Error)\b', process.stderr))
            instructions = json.loads((case/'metrics.json').read_text())['dynamic_instructions']
            row = {'case':case.name,'passed':passed,'returncode':process.returncode,
                   'elapsed_seconds':time.monotonic()-started,'log_sha256':digest(log),
                   'cycles':int(match[1]) if match else None, 'instructions':instructions}
            report['results'].append(row);save()
            if not passed:
                raise RuntimeError('official case failed: '+case.name)
            print('PASS',case.name,row['cycles'],flush=True)
        perf = [r for r in report['results'] if r['case'].startswith('perf_')]
        assert len(perf) == 6
        report['geomean'] = math.exp(sum(math.log(r['instructions']/r['cycles']) for r in perf)/6)
        report['sources_unchanged'] = all(digest(Path(p)) == h for p,h in hashes.items())
        report['completed'] = True;report['passed'] = report['sources_unchanged']
        if not report['passed']:
            raise RuntimeError('qualification inputs changed')
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
