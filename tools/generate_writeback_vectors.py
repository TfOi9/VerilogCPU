#!/usr/bin/env python3

import argparse
from pathlib import Path


def selected_sources(start, mask, source_count, backend_width):
    selected = []
    for offset in range(source_count):
        source = start + offset
        if source >= source_count:
            source -= source_count
        if mask & (1 << source):
            selected.append(source)
            if len(selected) == backend_width:
                break
    return selected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--sources", type=int, required=True)
    args = parser.parse_args()

    if args.width not in (1, 2, 4):
        raise SystemExit("width must be 1, 2, or 4")
    if args.sources < 1:
        raise SystemExit("sources must be positive")

    lines = []
    for start in range(args.sources):
        for mask in range(1 << args.sources):
            selected = selected_sources(
                start, mask, args.sources, args.width)
            padded = selected + [-1] * (4 - len(selected))
            lines.append(
                "{} {} {} {} {} {} {}\n".format(
                    start, mask, len(selected), *padded))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(lines), encoding="ascii")


if __name__ == "__main__":
    main()
