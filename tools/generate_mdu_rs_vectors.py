#!/usr/bin/env python3

import argparse
import random


MASK32 = (1 << 32) - 1
OP_MUL = 41
OP_MULH = 42
OP_MULHSU = 43
OP_MULHU = 44
OP_DIV = 45
OP_DIVU = 46
OP_REM = 47
OP_REMU = 48


def unsigned32(value):
    return value & MASK32


def signed32(value):
    value &= MASK32
    return value - (1 << 32) if value & (1 << 31) else value


def trunc_dividend(lhs, rhs):
    quotient = abs(lhs) // abs(rhs)
    return -quotient if (lhs < 0) != (rhs < 0) else quotient


def model(op, lhs, rhs):
    lhs_u = unsigned32(lhs)
    rhs_u = unsigned32(rhs)
    lhs_s = signed32(lhs)
    rhs_s = signed32(rhs)

    if op == OP_MUL:
        return unsigned32(lhs_u * rhs_u)
    if op == OP_MULH:
        return unsigned32((lhs_s * rhs_s) >> 32)
    if op == OP_MULHSU:
        return unsigned32((lhs_s * rhs_u) >> 32)
    if op == OP_MULHU:
        return unsigned32((lhs_u * rhs_u) >> 32)
    if op == OP_DIV:
        if rhs_u == 0:
            return MASK32
        if lhs_u == 0x80000000 and rhs_u == MASK32:
            return 0x80000000
        return unsigned32(trunc_dividend(lhs_s, rhs_s))
    if op == OP_DIVU:
        return MASK32 if rhs_u == 0 else lhs_u // rhs_u
    if op == OP_REM:
        if rhs_u == 0:
            return lhs_u
        if lhs_u == 0x80000000 and rhs_u == MASK32:
            return 0
        quotient = trunc_dividend(lhs_s, rhs_s)
        return unsigned32(lhs_s - quotient * rhs_s)
    if op == OP_REMU:
        return lhs_u if rhs_u == 0 else lhs_u % rhs_u
    raise ValueError(f"unsupported op {op}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--random-per-op", type=int, default=12)
    parser.add_argument("--seed", type=int, default=20260823)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    multiply_ops = (OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU)
    divide_ops = (OP_DIV, OP_DIVU, OP_REM, OP_REMU)
    edges = (
        (0, 0),
        (1, 1),
        (MASK32, 1),
        (0x80000000, MASK32),
        (0x7fffffff, 3),
        (0x80000000, 2),
    )

    rows = []
    tag = 0
    for unit_class, ops in ((0, multiply_ops), (1, divide_ops)):
        for op in ops:
            operands = list(edges)
            operands.extend(
                (rng.getrandbits(32), rng.getrandbits(32))
                for _ in range(args.random_per_op)
            )
            for lhs, rhs in operands:
                ready_mask = rng.randrange(4)
                delay = rng.randrange(1, 5)
                stall = rng.randrange(4)
                rows.append(
                    (unit_class, op, lhs, rhs, model(op, lhs, rhs),
                     tag & 0x3f, ready_mask, delay, stall)
                )
                tag += 1

    with open(args.output, "w", encoding="ascii") as output_file:
        for row in rows:
            unit_class, op, lhs, rhs, expected, item_tag, ready, delay, stall = row
            output_file.write(
                f"{unit_class:d} {op:d} {lhs:08x} {rhs:08x} "
                f"{expected:08x} {item_tag:x} {ready:d} {delay:d} {stall:d}\n"
            )


if __name__ == "__main__":
    main()
