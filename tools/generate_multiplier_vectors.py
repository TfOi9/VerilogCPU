#!/usr/bin/env python3

import argparse
import random
from pathlib import Path


OP_MUL = 41
OP_MULH = 42
OP_MULHSU = 43
OP_MULHU = 44
OPS = (OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU)
MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1


def signed32(value):
    value &= MASK32
    if value & (1 << 31):
        return value - (1 << 32)
    return value


def expected_value(op, lhs, rhs):
    lhs &= MASK32
    rhs &= MASK32
    if op == OP_MUL:
        product = lhs * rhs
        return product & MASK32
    if op == OP_MULH:
        product = signed32(lhs) * signed32(rhs)
    elif op == OP_MULHSU:
        product = signed32(lhs) * rhs
    elif op == OP_MULHU:
        product = lhs * rhs
    else:
        return 0
    return ((product & MASK64) >> 32) & MASK32


def add_vector(vectors, op, lhs, rhs):
    vectors.append((op, lhs & MASK32, rhs & MASK32,
                    expected_value(op, lhs, rhs)))


def build_vectors(random_count, seed):
    vectors = []
    key_values = (
        0x00000000, 0x00000001, 0x00000002, 0x00000003,
        0x00000007, 0x7ffffffe, 0x7fffffff, 0x80000000,
        0x80000001, 0xfffffffe, 0xffffffff, 0x55555555,
        0xaaaaaaaa, 0x0000ffff, 0xffff0000, 0x00ff00ff,
        0xff00ff00, 0x01010101, 0x80808080, 0xdeadbeef,
    )

    for op in OPS:
        for lhs in key_values:
            for rhs in key_values:
                add_vector(vectors, op, lhs, rhs)

    partners = (
        0x00000000, 0x00000001, 0xffffffff, 0x7fffffff,
        0x80000000, 0x55555555, 0xaaaaaaaa, 0xdeadbeef,
    )
    for bit_index in range(32):
        one_hot = 1 << bit_index
        patterns = (one_hot, (~one_hot) & MASK32,
                    (one_hot - 1) & MASK32, (one_hot + 1) & MASK32)
        for pattern in patterns:
            for partner in partners:
                for op in OPS:
                    add_vector(vectors, op, pattern, partner)
                    add_vector(vectors, op, partner, pattern)

    # Every radix-4 code is reachable in an interior group.
    for booth_code in range(8):
        middle_rhs = booth_code << 15
        for op in OPS:
            add_vector(vectors, op, 0x87654321, middle_rhs)

    # The low group has an implicit zero below bit zero.
    for booth_code in (0, 2, 4, 6):
        low_rhs = booth_code >> 1
        for op in OPS:
            add_vector(vectors, op, 0x87654321, low_rhs)

    # The high group is constrained by signed or zero extension.
    for high_rhs in (0x00000000, 0x80000000,
                     0x40000000, 0xc0000000, 0xffffffff):
        for op in OPS:
            add_vector(vectors, op, 0x87654321, high_rhs)

    rng = random.Random(seed)
    for _ in range(random_count):
        add_vector(vectors, rng.choice(OPS),
                   rng.getrandbits(32), rng.getrandbits(32))

    return vectors


def main():
    parser = argparse.ArgumentParser(
        description="Generate deterministic RV32M multiplier vectors")
    parser.add_argument("output", type=Path)
    parser.add_argument("--random-count", type=int, default=20000)
    parser.add_argument("--seed", type=lambda value: int(value, 0),
                        default=0x6d756c33)
    args = parser.parse_args()

    if args.random_count < 20000:
        parser.error("--random-count must be at least 20000")

    vectors = build_vectors(args.random_count, args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as output_file:
        for op, lhs, rhs, expected in vectors:
            output_file.write(
                "{0:02x} {1:08x} {2:08x} {3:08x}\n".format(
                    op, lhs, rhs, expected))

    print("Generated {0} multiplier vectors in {1}".format(
        len(vectors), args.output))


if __name__ == "__main__":
    main()
