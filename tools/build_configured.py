#!/usr/bin/env python3
"""Build the official simulator with explicit student_top parameters."""

import argparse
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework", type=Path, required=True)
    parser.add_argument("--filelist", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fe-width", type=int, required=True)
    parser.add_argument("--be-width", type=int, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--appimage", default="")
    parser.add_argument("--verilator")
    parser.add_argument("--cxx", default="g++")
    parser.add_argument("--ar", default="ar")
    parser.add_argument("--make", default="make")
    return parser.parse_args()


def main():
    args = parse_args()
    if args.fe_width not in (1, 2) or args.be_width not in (1, 2):
        raise ValueError("configured build widths must be 1 or 2")
    if args.fe_width != args.be_width:
        raise ValueError("configured build requires matching FE/BE widths")
    if args.jobs < 1:
        raise ValueError("jobs must be positive")

    framework = args.framework.resolve()
    scripts = framework / "scripts"
    if not scripts.is_dir():
        raise ValueError("framework scripts directory does not exist: {}".format(
            scripts))
    sys.path.insert(0, str(scripts))

    from build import read_sources, verilator_command
    from fakeram import with_ram_source
    from toolchain import DEFAULT_APPIMAGE, enter_appimage, executable

    if not args.verilator:
        enter_appimage(args.appimage or str(DEFAULT_APPIMAGE))
    sources = read_sources(args.filelist)
    verilator = verilator_command(args.verilator)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "sim"
    if binary.exists():
        binary.unlink()
    objects = out / "obj"
    if objects.is_symlink():
        objects.unlink()
    elif objects.exists():
        shutil.rmtree(str(objects))

    environment = os.environ.copy()
    environment["MAKE"] = executable(args.make)
    make_flags = " ".join(shlex.quote("{}={}".format(key, value)) for key, value in {
        "CXX": executable(args.cxx),
        "LINK": executable(args.cxx),
        "AR": executable(args.ar),
        "PYTHON3": sys.executable,
    }.items())
    command = [
        verilator,
        "--cc", "--exe", "--build", "--trace", "--assert",
        "-Wall", "-Wno-fatal", "--top-module", "student_top",
        "--Mdir", str(objects), "-o", str(binary),
        "-j", str(args.jobs), "-MAKEFLAGS", make_flags,
        "-CFLAGS", "-std=c++17",
        "-GFE_WIDTH={}".format(args.fe_width),
        "-GBE_WIDTH={}".format(args.be_width),
    ]
    command.extend(str(path) for path in with_ram_source(sources))
    command.append(str(scripts / "sim.cpp"))
    subprocess.run(command, check=True, env=environment)
    print(binary)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        print("error: {}".format(error), file=sys.stderr)
        sys.exit(2)
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
