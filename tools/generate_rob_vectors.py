#!/usr/bin/env python3

import argparse
import random


def generate(entries, width, generation_bits, cycles, output_path):
    if entries < width or entries < 2 or entries & (entries - 1):
        raise ValueError("entries must be a power of two and at least width")
    if width not in (1, 2, 4):
        raise ValueError("width must be 1, 2, or 4")

    index_bits = (entries - 1).bit_length()
    generation_mask = (1 << generation_bits) - 1
    next_generation = [0] * entries
    queue = []
    tail = 0
    rng = random.Random(0x524F4239 ^ entries ^ width)

    with open(output_path, "w") as output_file:
        for cycle in range(cycles):
            ready_count = rng.randrange(width + 1)
            ready_mask = (1 << ready_count) - 1
            alloc_count = min(rng.randrange(width + 1), entries - len(queue))
            base_pc = 0x9000 + cycle * 16

            commit_count = min(width, len(queue))
            fire_count = min(ready_count, commit_count)
            commit_valid_mask = (1 << commit_count) - 1
            commit_fire_mask = (1 << fire_count) - 1
            commit_pcs = [0] * 4
            alloc_tags = [0] * 4

            for lane in range(commit_count):
                commit_pcs[lane] = queue[lane][0]
            for lane in range(alloc_count):
                slot = (tail + lane) & (entries - 1)
                alloc_tags[lane] = (
                    (next_generation[slot] << index_bits) | slot
                )

            fields = [
                "%x" % ready_mask,
                str(alloc_count),
                "%08x" % base_pc,
                str(len(queue)),
                "%x" % commit_valid_mask,
                "%x" % commit_fire_mask,
            ]
            fields.extend("%08x" % value for value in commit_pcs)
            fields.extend("%x" % value for value in alloc_tags)
            output_file.write(" ".join(fields) + "\n")

            del queue[:fire_count]
            for lane in range(alloc_count):
                slot = (tail + lane) & (entries - 1)
                queue.append((base_pc + lane * 4, alloc_tags[lane]))
                next_generation[slot] = (
                    next_generation[slot] + 1
                ) & generation_mask
            tail = (tail + alloc_count) & (entries - 1)


def main():
    parser = argparse.ArgumentParser(
        description="Generate randomized reorder-buffer reference vectors"
    )
    parser.add_argument("output")
    parser.add_argument("--entries", type=int, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--generation-bits", type=int, default=2)
    parser.add_argument("--cycles", type=int, default=400)
    args = parser.parse_args()
    generate(
        args.entries,
        args.width,
        args.generation_bits,
        args.cycles,
        args.output,
    )


if __name__ == "__main__":
    main()
