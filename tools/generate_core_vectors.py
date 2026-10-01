#!/usr/bin/env python3
"""Generate RV32IM programs and an architectural retirement reference."""

import argparse
import random
from pathlib import Path

from generate_mdu_rs_vectors import model as mdu_result

MASK = 0xffffffff


def signed(value, bits=32):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def immediate(rd, rs, value, funct=0, opcode=0x13):
    return ((value & 0xfff) << 20) | (rs << 15) | (funct << 12) | (rd << 7) | opcode


def register(rd, lhs, rhs, funct=0, high=0):
    return (high << 25) | (rhs << 20) | (lhs << 15) | (funct << 12) | (rd << 7) | 0x33


def store(rs, base, offset, funct=2):
    offset &= 0xfff
    return ((offset >> 5) << 25) | (rs << 20) | (base << 15) | (funct << 12) | ((offset & 31) << 7) | 0x23


def branch(lhs, rhs, offset, funct=0):
    return (((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) | (rhs << 20) | (lhs << 15) | (funct << 12) | (((offset >> 1) & 15) << 8) | (((offset >> 11) & 1) << 7) | 0x63


def execute(words):
    registers = [0] * 32
    memory = bytearray(4096)
    trace = []
    pc = 0
    for _ in range(20000):
        instruction = words[pc // 4]
        opcode = instruction & 127
        rd = (instruction >> 7) & 31
        funct = (instruction >> 12) & 7
        lhs = registers[(instruction >> 15) & 31]
        rhs = registers[(instruction >> 20) & 31]
        high = instruction >> 25
        value = 0
        writes = opcode in (0x13, 0x33, 0x37, 0x03, 0x67, 0x6f) and rd != 0
        next_pc = pc + 4
        done = False
        if opcode == 0x37:
            value = instruction & 0xfffff000
        elif opcode == 0x13:
            imm = signed(instruction >> 20, 12)
            shift = imm & 31
            value = {0: lambda: lhs + imm, 1: lambda: lhs << shift,
                     2: lambda: int(signed(lhs) < imm), 3: lambda: int(lhs < (imm & MASK)),
                     4: lambda: lhs ^ (imm & MASK), 5: lambda: signed(lhs) >> shift if high == 32 else lhs >> shift,
                     6: lambda: lhs | (imm & MASK), 7: lambda: lhs & (imm & MASK)}[funct]()
        elif opcode == 0x33:
            if high == 1:
                value = mdu_result(41 + funct, lhs, rhs)
            else:
                value = {0: lambda: lhs - rhs if high == 32 else lhs + rhs,
                         1: lambda: lhs << (rhs & 31), 2: lambda: int(signed(lhs) < signed(rhs)),
                         3: lambda: int(lhs < rhs), 4: lambda: lhs ^ rhs,
                         5: lambda: signed(lhs) >> (rhs & 31) if high == 32 else lhs >> (rhs & 31),
                         6: lambda: lhs | rhs, 7: lambda: lhs & rhs}[funct]()
        elif opcode == 0x03:
            address = (lhs + signed(instruction >> 20, 12)) & MASK
            size = 1 << (funct & 3)
            raw = int.from_bytes(memory[address - 0x10000:address - 0x10000 + size], "little")
            value = raw if funct & 4 else signed(raw, size * 8)
        elif opcode == 0x23:
            offset = ((instruction >> 25) << 5) | ((instruction >> 7) & 31)
            address = (lhs + signed(offset, 12)) & MASK
            size = 1 << funct
            if address == 0x80000000:
                if size != 4:
                    raise ValueError("bad exit store")
                done = True
            else:
                offset = address - 0x10000
                memory[offset:offset + size] = (rhs & ((1 << (size * 8)) - 1)).to_bytes(size, "little")
        elif opcode == 0x63:
            offset = (((instruction >> 31) & 1) << 12) | (((instruction >> 7) & 1) << 11) | (((instruction >> 25) & 63) << 5) | (((instruction >> 8) & 15) << 1)
            taken = {0: lhs == rhs, 1: lhs != rhs, 4: signed(lhs) < signed(rhs),
                     5: signed(lhs) >= signed(rhs), 6: lhs < rhs, 7: lhs >= rhs}[funct]
            if taken:
                next_pc = pc + signed(offset, 13)
        elif opcode == 0x67:
            value = pc + 4
            next_pc = (lhs + signed(instruction >> 20, 12)) & 0xfffffffe
        elif opcode == 0x6f:
            offset = (((instruction >> 31) & 1) << 20) | (((instruction >> 12) & 255) << 12) | (((instruction >> 20) & 1) << 11) | (((instruction >> 21) & 1023) << 1)
            value = pc + 4
            next_pc = pc + signed(offset, 21)
        else:
            raise ValueError("unsupported instruction {:08x}".format(instruction))
        value &= MASK
        trace.append((pc, instruction, int(writes), rd if writes else 0, value if writes else 0))
        if writes:
            registers[rd] = value
        registers[0] = 0
        if done:
            return trace, rhs
        pc = next_pc
    raise ValueError("reference did not terminate")


def generate(seed):
    rng = random.Random(seed)
    words = [immediate(1, 0, 600), immediate(2, 0, 3), 0x00010f37, 0x80000fb7,
             register(3, 1, 2, 5, 1)]
    words += [immediate(rd, 3, rd) for rd in range(4, 8)]
    words += [immediate(4, 4, 3), register(8, 4, 5)]
    words += [register(3, 1, 2, 5, 1), branch(3, 3, 24), branch(3, 3, 16),
              store(0, 31, 0), store(1, 30, 0), register(21, 1, 2, 0, 1),
              register(22, 1, 2, 4, 1)]
    target = (len(words) + 3) * 4
    words += [immediate(29, 0, target), immediate(28, 29, 0, opcode=0x67), store(0, 31, 0)]
    for rd in range(9, 28):
        words.append(immediate(rd, 0, rng.randrange(-2048, 2048)))
    for index in range(700):
        rd, lhs, rhs = [rng.randrange(1, 28) for _ in range(3)]
        choice = rng.randrange(6)
        if index % 41 == 0:
            words += [register(20, 1, 2, 5, 1), branch(20, 20, 24),
                      immediate(23, 30, 256, 2, 0x03),
                      store(0, 31, 0), store(0, 30, 256),
                      register(21, 1, 2, 0, 1), register(22, 1, 2, 4, 1)]
        elif choice == 0:
            words.append(register(rd, lhs, rhs, rng.randrange(8), 1))
        elif choice == 1:
            funct = rng.randrange(8)
            high = 32 if funct in (0, 5) and rng.randrange(2) else 0
            words.append(register(rd, lhs, rhs, funct, high))
        elif choice == 2:
            funct = rng.randrange(8)
            value = rng.randrange(-2048, 2048)
            if funct in (1, 5):
                value = rng.randrange(32) | (1024 if funct == 5 and rng.randrange(2) else 0)
            words.append(immediate(rd, lhs, value, funct))
        elif choice == 3:
            funct = rng.choice((0, 1, 2))
            offset = rng.randrange(32) * 4
            words.append(store(rhs, 30, offset, funct))
            words.append(immediate(rd, 30, offset, rng.choice((funct, funct | 4)) if funct != 2 else 2, 0x03))
        elif choice == 4:
            words.append(branch(lhs, rhs, 8, rng.choice((0, 1, 4, 5, 6, 7))))
            words.append(immediate(rd, lhs, 1))
        else:
            words.append(immediate(0, lhs, rng.randrange(-32, 32)))
    words += [register(10, 4, 8), store(10, 31, 0), 0x0000006f]
    return words


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x2401)
    args = parser.parse_args()
    words = generate(args.seed)
    trace, result = execute(words)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.with_suffix(".words").write_text("\n".join("{:08x}".format(word) for word in words) + "\n", encoding="ascii")
    args.out.with_suffix(".trace").write_text("".join("{:08x} {:08x} {} {} {:08x}\n".format(*row) for row in trace), encoding="ascii")
    args.out.with_suffix(".result").write_text(str(result) + "\n", encoding="ascii")
    print("seed={} words={} retired={} result={}".format(args.seed, len(words), len(trace), result))


if __name__ == "__main__":
    main()
