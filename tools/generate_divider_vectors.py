#!/usr/bin/env python3

import argparse
import random
from pathlib import Path


OP_DIV = 45
OP_DIVU = 46
OP_REM = 47
OP_REMU = 48
OPS = (OP_DIV, OP_DIVU, OP_REM, OP_REMU)
MASK32 = (1 << 32) - 1


def signed32(value):
    value &= MASK32
    if value & (1 << 31):
        return value - (1 << 32)
    return value


def expected_value(op, lhs, rhs):
    lhs &= MASK32
    rhs &= MASK32
    if op in (OP_DIV, OP_REM):
        signed_lhs = signed32(lhs)
        signed_rhs = signed32(rhs)
        if signed_rhs == 0:
            quotient = -1
            remainder = signed_lhs
        else:
            quotient_magnitude = abs(signed_lhs) // abs(signed_rhs)
            quotient = (-quotient_magnitude
                        if (signed_lhs < 0) != (signed_rhs < 0)
                        else quotient_magnitude)
            remainder = signed_lhs - quotient * signed_rhs
        result = quotient if op == OP_DIV else remainder
        return result & MASK32

    if rhs == 0:
        quotient = MASK32
        remainder = lhs
    else:
        quotient = lhs // rhs
        remainder = lhs - quotient * rhs
    return quotient if op == OP_DIVU else remainder


def add_vector(vectors, op, lhs, rhs):
    vectors.append((op, lhs & MASK32, rhs & MASK32,
                    expected_value(op, lhs, rhs)))


def build_vectors(random_count, seed):
    vectors = []
    key_values = (
        0x00000000, 0x00000001, 0x00000002, 0x00000003,
        0x00000007, 0x00000008, 0x0000000f, 0x00000010,
        0x7ffffffe, 0x7fffffff, 0x80000000, 0x80000001,
        0xfffffff0, 0xfffffff9, 0xfffffffe, 0xffffffff,
        0x55555555, 0xaaaaaaaa, 0xdeadbeef,
    )

    for op in OPS:
        for lhs in key_values:
            for rhs in key_values:
                add_vector(vectors, op, lhs, rhs)

    partners = (
        0x00000000, 0x00000001, 0xffffffff,
        0x7fffffff, 0x80000000, 0x55555555,
    )
    for bit_index in range(32):
        one_hot = 1 << bit_index
        patterns = (
            one_hot,
            (~one_hot) & MASK32,
            (one_hot - 1) & MASK32,
            (one_hot + 1) & MASK32,
        )
        for pattern in patterns:
            for partner in partners:
                for op in OPS:
                    add_vector(vectors, op, pattern, partner)
                    add_vector(vectors, op, partner, pattern)

    rng = random.Random(seed)
    for _ in range(random_count):
        add_vector(vectors, rng.choice(OPS),
                   rng.getrandbits(32), rng.getrandbits(32))

    return vectors


def main():
    parser = argparse.ArgumentParser(
        description="Generate deterministic RV32M divider vectors")
    parser.add_argument("output", type=Path)
    parser.add_argument("--random-count", type=int, default=5000)
    parser.add_argument("--seed", type=lambda value: int(value, 0),
                        default=0x64697632)
    args = parser.parse_args()

    if args.random_count < 5000:
        parser.error("--random-count must be at least 5000")

    vectors = build_vectors(args.random_count, args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as output_file:
        for op, lhs, rhs, expected in vectors:
            output_file.write(
                "{0:02x} {1:08x} {2:08x} {3:08x}\n".format(
                    op, lhs, rhs, expected))

    print("Generated {0} divider vectors in {1}".format(
        len(vectors), args.output))


if __name__ == "__main__":
    main()
