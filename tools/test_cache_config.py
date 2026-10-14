#!/usr/bin/env python3
"""Check explicit cache overrides before an expensive simulator build."""

import argparse
import unittest

from build_configured import cache_geometry, cache_options


class CacheConfigTest(unittest.TestCase):
    def test_geometry_and_flags(self):
        self.assertEqual(cache_geometry("4096,2"), (4096, 128, 2))
        self.assertEqual(cache_options(cache_geometry("2048,1"), cache_geometry("16384,2")), [
            "-GICACHE_SIZE_BYTES=2048", "-GICACHE_NUM_SETS=128", "-GICACHE_NUM_WAYS=1",
            "-GDCACHE_SIZE_BYTES=16384", "-GDCACHE_NUM_SETS=512", "-GDCACHE_NUM_WAYS=2",
        ])

    def test_defaults_preserved(self):
        self.assertEqual(cache_options(), [])
        self.assertFalse(any("ICACHE" in flag for flag in
                             cache_options(dcache=cache_geometry("4096,2"))))

    def test_invalid_geometry(self):
        for value in ("4096", "4096,2,1", "x,2", "4096,0", "-32,1", "4096,-1",
                      "4095,2", "32,2", "96,1", "0,2"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                cache_geometry(value)


if __name__ == "__main__":
    unittest.main()
