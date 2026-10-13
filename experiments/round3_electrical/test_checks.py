#!/usr/bin/env python3
"""Negative controls against real mapped CPU artifacts and full reconstruction."""
import copy
import json
from pathlib import Path
import shutil
import unittest
from repair import ROOT, OUT, evaluate_full, is_fixed, verify


class ReconstructionGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        verify()
        cls.original = ROOT/'build/round2-20261013/baseline/synth/1x1-p48-r16/opt'
        run = json.loads((OUT/'closed/baseline/1x1-p48-r16/run.json').read_text())
        cls.source = json.loads((Path(run['final_directory'])/'design.json').read_text())
        cls.target = OUT/'negative-controls'
        if cls.target.exists():
            shutil.rmtree(cls.target)
        cls.target.mkdir()

    def candidate(self):
        return copy.deepcopy(self.source)

    def test_state_input_corruption_is_rejected(self):
        candidate = self.candidate()
        cell = next(c for c in candidate['modules']['student_top']['cells'].values()
                    if c['type'].startswith('DFF'))
        cell['connections']['D'] = cell['connections']['CLK'][:]
        with self.assertRaisesRegex(ValueError, 'fixed state/constant cells changed'):
            evaluate_full(self.original, self.target/'state', candidate)

    def test_port_rename_is_rejected(self):
        candidate = self.candidate()
        ports = candidate['modules']['student_top']['ports']
        ports['corrupt_reset'] = ports.pop('reset')
        with self.assertRaisesRegex(ValueError, 'top interface changed'):
            evaluate_full(self.original, self.target/'interface', candidate)

    def test_observable_logic_inversion_is_rejected(self):
        candidate = self.candidate()
        top = candidate['modules']['student_top']
        boundary_inputs = {b for c in top['cells'].values() if is_fixed(c)
                           for p, bits in c['connections'].items()
                           if c['port_directions'][p] == 'input' for b in bits}
        cell = next(c for n, c in top['cells'].items() if n.startswith('repair.hold')
                    and c['type'].startswith('BUF') and c['connections']['Y'][0] in boundary_inputs)
        cell['type'] = 'INVx1_ASAP7_75t_R'
        with self.assertRaisesRegex(ValueError, 'full-boundary equivalence failed'):
            evaluate_full(self.original, self.target/'logic', candidate)
        text = (self.target/'logic/reconstruction-cec.log').read_text()
        self.assertIn('NOT EQUIVALENT', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
