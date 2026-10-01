#!/usr/bin/env python3
"""Generate independent age-sorted issue arbitration reference vectors."""

import argparse
import random
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, choices=(1, 2, 4), required=True)
    args = parser.parse_args()
    count = args.width + 4
    rng = random.Random(0x49535355 + args.width)
    rows = []
    scenarios = [(head, mask, ready, 0)
                 for head in (0, 31)
                 for mask in range(1 << count)
                 for ready in (0, mask, (1 << count) - 1, 0x55)]
    scenarios += [(rng.randrange(32), rng.randrange(1 << count),
                   rng.randrange(1 << count), int(rng.random() < 0.1))
                  for _ in range(4000)]
    for head, valid, ready, hold in scenarios:
        tags = [index | (rng.randrange(4) << 5)
                for index in rng.sample(range(32), count)]
        candidates = sorted((index for index in range(count)
                             if valid & ready & (1 << index)),
                            key=lambda index: ((tags[index] - head) % 32, index))
        selected = []
        for index in candidates:
            if index >= args.width + 2 and any(
                    other >= args.width + 2 for other in selected):
                continue
            selected.append(index)
            if len(selected) == args.width:
                break
        grant = 0 if hold else sum(1 << index for index in selected)
        packed = sum(tag << (7 * index) for index, tag in enumerate(tags))
        rows.append("{} {:x} {:x} {:x} {:x} {:x}\n".format(
            hold, head, valid, ready, packed, grant))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(rows), encoding="ascii")


if __name__ == "__main__":
    main()
