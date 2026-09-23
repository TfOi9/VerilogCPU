#!/usr/bin/env python3
"""Validate the bare-metal image pipeline with the accumulation program."""

from __future__ import print_function

import os
import json
import sys
import tempfile

import make_image


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "tests", "programs", "accumulate.c")
MMIO_EXIT_SEQUENCE = bytes.fromhex("b7 02 00 80 23 a0 a2 00")


def parse_image(path):
    segments = []
    current = None
    with open(path) as stream:
        for line_number, raw_line in enumerate(stream, 1):
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith("@"):
                if len(line) != 9:
                    raise AssertionError("bad image address on line {}".format(line_number))
                current = [int(line[1:], 16), bytearray()]
                segments.append(current)
                continue
            if current is None:
                raise AssertionError("bytes precede an image address")
            for token in line.split():
                if len(token) != 2 or any(char not in "0123456789abcdefABCDEF" for char in token):
                    raise AssertionError("bad byte on line {}".format(line_number))
                current[1].append(int(token, 16))
    return segments


def main():
    with tempfile.TemporaryDirectory(prefix="image-test-",
                                     dir=os.path.join(ROOT, "build")) as out_dir:
        for arch in ("rv32i", "rv32im"):
            arch_dir = os.path.join(out_dir, arch)
            os.makedirs(arch_dir)
            make_image.main([SOURCE, "--arch", arch, "--out-dir", arch_dir])

            image = os.path.join(arch_dir, "accumulate.image")
            binary = os.path.join(arch_dir, "accumulate.bin")
            elf = os.path.join(arch_dir, "accumulate.elf")
            manifest = os.path.join(arch_dir, "accumulate.json")
            segments = parse_image(image)
            assert segments and segments[0][0] == 0
            for address, data in segments:
                assert address < make_image.MEMORY_SIZE
                assert address + len(data) <= make_image.MEMORY_SIZE
            rom = next(data for address, data in segments if address == 0)
            assert bytes(rom).find(MMIO_EXIT_SEQUENCE) >= 0
            assert os.path.getsize(binary) <= make_image.MEMORY_SIZE
            assert os.path.isfile(elf)

            with open(binary, "rb") as stream:
                raw = stream.read()
            for address, data in segments:
                assert raw[address:address + len(data)] == bytes(data)
            with open(manifest) as stream:
                metadata = json.load(stream)
            assert metadata["entry"] == "0x00000000"
            assert "halt_instruction" not in metadata
            assert "halt_address" not in metadata
            assert int(metadata["memory_size"]) == make_image.MEMORY_SIZE
            assert any(
                item["memory_size"] > item["file_size"]
                for item in metadata["segments"]
            )
            for item in metadata["segments"]:
                address = int(item["address"], 16)
                assert address + item["memory_size"] <= make_image.MEMORY_SIZE

            print("PASS {} accumulation image".format(arch))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError) as exc:
        print("FAIL: {}".format(exc), file=sys.stderr)
        sys.exit(1)
