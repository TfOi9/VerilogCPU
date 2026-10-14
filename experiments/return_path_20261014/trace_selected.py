#!/usr/bin/env python3
"""Replay only the pre-ABC prefix for an exact selected endpoint state audit."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT/'build/return-path-20261014/selected-path'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--measurement', required=True)
    parser.add_argument('--phase', choices=('replay', 'audit'), required=True)
    args = parser.parse_args()
    ppa = ROOT/'build/return-path-20261014'/args.measurement/'ppa/opt'
    if args.phase == 'replay':
        OUT.mkdir(parents=True, exist_ok=False)
        script = (ppa/'synth.ys').read_text().split('\nabc -exe ', 1)[0]
        script += '\nwrite_json "'+str(OUT/'preabc.json')+'"\n'
        (OUT/'preabc.ys').write_text(script)
        command = ['timeout', '-k', '5', '1200', str(ROOT/'.deps/yosys/bin/yosys'),
                   '-q', '-s', str(OUT/'preabc.ys')]
        (OUT/'command.json').write_text(json.dumps(command, indent=2)+'\n')
        with (OUT/'preabc.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        assert result.returncode == 0
    else:
        spec = importlib.util.spec_from_file_location('endpoint_audit', HERE/'paths.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.OUT, module.PPA = OUT, ppa
        module.main()


if __name__ == '__main__':
    main()
