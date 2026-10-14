#!/usr/bin/env python3
"""Negative controls for state-cut equivalence and positive-margin audit gates."""
import copy
import json
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch
from stage import ROOT, OUT
from prove import cut, yosys
from repair import execute
import margin


class Guards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proof = OUT/'proof/rv32_completion_writeback_network/4x4-p64-r16'
        cls.original = json.loads((cls.proof/'gold.json').read_text())['modules']['rv32_completion_writeback_network']
        cls.modified = json.loads((cls.proof/'gate.json').read_text())['modules']['rv32_completion_writeback_network']
        cls.target = OUT/'negative-controls'
        if cls.target.exists():
            shutil.rmtree(cls.target)
        cls.target.mkdir()

    def test_clock_change_rejected(self):
        old, new = copy.deepcopy(self.original), copy.deepcopy(self.modified)
        cell = next(c for c in new['cells'].values() if c['type'].startswith('$_DFF_'))
        cell['connections']['C'] = new['ports']['reset_i']['bits'][:]
        with self.assertRaisesRegex(ValueError, 'clock input correspondence differs'):
            cut(old, new, self.target, 'rv32_completion_writeback_network')

    def test_missing_state_rejected(self):
        old, new = copy.deepcopy(self.original), copy.deepcopy(self.modified)
        name = next(n for n, c in new['cells'].items() if c['type'].startswith('$_DFF_'))
        del new['cells'][name]
        with self.assertRaisesRegex(ValueError, 'state correspondence is incomplete'):
            cut(old, new, self.target, 'rv32_completion_writeback_network')

    def test_observable_logic_corruption_rejected(self):
        source = json.loads((self.proof/'gate-cut.json').read_text())
        top = source['modules']['rv32_completion_writeback_network']
        bit = top['ports']['completion_valid_o']['bits'][0]
        driver = next(c for c in top['cells'].values() if c['connections'].get('Y') == [bit])
        self.assertEqual(driver['type'], '$_AND_')
        driver['type'] = '$_NAND_'
        (self.target/'bad.json').write_text(json.dumps(source))
        yosys(['read_json '+str(self.target/'bad.json'), 'hierarchy -top rv32_completion_writeback_network',
               'check -assert', 'write_blif '+str(self.target/'bad.blif')], self.target, 'bad')
        execute([ROOT/'.deps/yosys/bin/yosys-abc', '-c',
                 'cec '+str(self.proof/'gold.blif')+' '+str(self.target/'bad.blif')], self.target/'bad-cec.log', 120)
        self.assertIn('NOT EQUIVALENT', (self.target/'bad-cec.log').read_text())

    def fake_margin_query(self, command, log, timeout):
        log.write_text('completed\n')
        checks = getattr(self, 'query_checks', [])
        (log.parent/'margin_paths.json').write_text(json.dumps({'checks': checks}))

    def test_empty_query_cannot_hide_small_positive_slack(self):
        directory = self.target/'empty'
        directory.mkdir()
        (directory/'hold.tcl').write_text('report_checks -path_delay min\nexit\n')
        hold = {'passed': True, 'worst_slack_ns': 0.015, 'violating_endpoints': 0, 'scope': 'test fixture'}
        with patch.object(margin, 'audit_hold', return_value=hold), patch.object(margin, 'execute', self.fake_margin_query):
            with self.assertRaisesRegex(ValueError, 'positive hold margin did not converge'):
                margin.close(directory, directory, directory/'closure')

    def test_truncated_margin_query_rejected(self):
        directory = self.target/'truncated'
        directory.mkdir()
        (directory/'hold.tcl').write_text('report_checks -path_delay min\nexit\n')
        hold = {'passed': True, 'worst_slack_ns': 0.015, 'violating_endpoints': 0, 'scope': 'test fixture'}
        self.query_checks = [{'endpoint': 'state/D', 'slack': 0.015e-9}]*2
        with patch.object(margin, 'LIMIT', 2), patch.object(margin, 'audit_hold', return_value=hold), patch.object(margin, 'execute', self.fake_margin_query):
            with self.assertRaisesRegex(ValueError, 'margin report may be truncated'):
                margin.audit(directory)


if __name__ == '__main__':
    unittest.main(verbosity=2)
