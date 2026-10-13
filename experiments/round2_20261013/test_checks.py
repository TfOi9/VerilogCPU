#!/usr/bin/env python3
"""Check that corrupted observations cannot silently pass experiment gates."""
import copy
import json
import unittest
from setup import OUT
from run import validate_profile
from electrical import parse

class ObservationGates(unittest.TestCase):
    def setUp(self):
        self.result = json.loads((OUT/'baseline/sim/2x2-p64-r32/perf_vvadd.json').read_text())

    def test_real_counter_conservation(self):
        self.assertTrue(all(validate_profile(self.result['profile'],self.result['cycles']).values()))

    def test_lost_retirement_is_rejected(self):
        profile = copy.deepcopy(self.result['profile'])
        profile['counts']['retired'] += 1
        self.assertFalse(all(validate_profile(profile,self.result['cycles']).values()))

    def test_duplicate_response_is_rejected(self):
        profile = copy.deepcopy(self.result['profile'])
        profile['counts']['cache_responses'] += 1
        self.assertFalse(all(validate_profile(profile,self.result['cycles']).values()))

    def test_missing_cycle_is_rejected(self):
        profile = copy.deepcopy(self.result['profile'])
        profile['counts']['partition_retire'] -= 1
        self.assertFalse(all(validate_profile(profile,self.result['cycles']).values()))

    def test_real_electrical_violations_are_not_a_pass(self):
        path = OUT/'baseline/synth/2x2-p64-r32/electrical'
        report = json.loads((path/'report.json').read_text())
        self.assertEqual(report['execution']['returncode'],0)
        self.assertFalse(report['electrical_pass'])
        self.assertGreater(parse((path/'audit.log').read_text(),'cap')['violating_pins'],0)

    def test_truncated_electrical_output_is_rejected(self):
        text = (OUT/'baseline/synth/2x2-p64-r32/electrical/audit.log').read_text()
        with self.assertRaises(ValueError):
            parse(text.replace('CAP_END',''),'cap')

    def test_unparsed_violation_is_rejected(self):
        with self.assertRaises(ValueError):
            parse('CAP_BEGIN\nunknown layout (VIOLATED)\nCAP_END','cap')

if __name__ == '__main__':
    unittest.main()
