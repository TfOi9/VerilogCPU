#!/usr/bin/env python3
"""Build a freestanding RV32I/RV32IM program and emit a sparse CPU image.

The stages are intentionally explicit:

    C -> C object -> ELF -> raw binary and @address byte image

The image format is the SORA-compatible format consumed by the reference
simulator: an ``@ADDRESS`` line selects a byte address and subsequent tokens
are little-endian bytes written at consecutive addresses.
"""

from __future__ import print_function

import argparse
import json
import os
import shlex
import struct
import subprocess
import sys


MEMORY_SIZE = 1024 * 1024
ROM_SIZE = 0x1000
HALT_WORD = 0x0FF00513
HALT_BYTES = struct.pack("<I", HALT_WORD)
PT_LOAD = 1
PF_X = 1
EM_RISCV = 243


def command_path(value, env_name, default):
    return os.environ.get(env_name, value or default)


def show_command(cmd):
    try:
        return shlex.join(cmd)
    except AttributeError:
        return " ".join(shlex.quote(item) for item in cmd)


def run(cmd, stdout=None):
    print("+ " + show_command(cmd))
    try:
        return subprocess.run(cmd, check=True, stdout=stdout)
    except OSError as exc:
        raise BuildError("cannot execute {}: {}".format(cmd[0], exc))
    except subprocess.CalledProcessError as exc:
        raise BuildError("command failed with exit status {}: {}".format(
            exc.returncode, show_command(cmd)))


class BuildError(Exception):
    pass


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="freestanding C source file")
    parser.add_argument(
        "--arch", choices=("rv32i", "rv32im"), default="rv32i",
        help="RISC-V ISA to compile (default: rv32i)")
    parser.add_argument("--abi", default="ilp32", help="ABI (default: ilp32)")
    parser.add_argument("--opt", default="-O2", help="GCC optimisation flag")
    parser.add_argument(
        "--out-dir", default=None,
        help="output directory (default: build/images/<name>-<arch>)")
    parser.add_argument(
        "-I", dest="includes", action="append", default=[],
        help="additional C include directory; may be repeated")
    parser.add_argument(
        "--cflag", action="append", default=[],
        help="additional compiler flag; may be repeated")
    parser.add_argument(
        "--keep-intermediates", action="store_true", default=True,
        help="keep object, ELF, dump and map files (default: true)")
    parser.add_argument(
        "--no-keep-intermediates", dest="keep_intermediates",
        action="store_false", help="remove object and diagnostic files")
    parser.add_argument("--startup", default=None, help="startup assembly path")
    parser.add_argument("--linker", default=None, help="linker script path")
    parser.add_argument("--runtime", default=None, help="runtime C path")
    parser.add_argument("--cc", default=None, help="RISC-V GCC executable")
    parser.add_argument("--objcopy", default=None, help="RISC-V objcopy executable")
    parser.add_argument("--objdump", default=None, help="RISC-V objdump executable")
    parser.add_argument("--readelf", default=None, help="RISC-V readelf executable")
    return parser.parse_args(argv)


def read_elf(elf_path):
    """Read enough ELF32 metadata to construct and validate load segments."""
    with open(elf_path, "rb") as stream:
        blob = stream.read()

    if len(blob) < 52 or blob[:4] != b"\x7fELF":
        raise BuildError("{} is not an ELF file".format(elf_path))
    if blob[4] != 1 or blob[5] != 1:
        raise BuildError("{} is not a little-endian ELF32 file".format(elf_path))

    fields = struct.unpack_from("<16sHHIIIIIHHHHHH", blob, 0)
    _, elf_type, machine, version, entry, phoff, shoff, flags, ehsize, phentsize, \
        phnum, shentsize, shnum, shstrndx = fields
    if machine != EM_RISCV:
        raise BuildError("{} is not an RISC-V ELF (machine {})".format(
            elf_path, machine))
    if phentsize < 32 or phoff + phentsize * phnum > len(blob):
        raise BuildError("{} has invalid program headers".format(elf_path))

    segments = []
    for index in range(phnum):
        offset = phoff + index * phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = \
            struct.unpack_from("<IIIIIIII", blob, offset)
        if p_type != PT_LOAD:
            continue
        if p_filesz > p_memsz:
            raise BuildError("ELF load segment {} has filesz > memsz".format(index))
        if p_offset + p_filesz > len(blob):
            raise BuildError("ELF load segment {} exceeds the file".format(index))
        address = p_paddr
        end = address + p_memsz
        if end > MEMORY_SIZE or end < address:
            raise BuildError(
                "ELF load segment {} exceeds the 1 MiB address range: "
                "0x{:08x}+0x{:x}".format(index, address, p_memsz))
        if p_filesz:
            data = blob[p_offset:p_offset + p_filesz]
        else:
            data = b""
        segments.append({
            "address": address,
            "file_size": p_filesz,
            "memory_size": p_memsz,
            "flags": p_flags,
            "align": p_align,
            "data": data,
        })

    segments.sort(key=lambda item: item["address"])
    previous_end = 0
    for segment in segments:
        if segment["address"] < previous_end:
            raise BuildError("overlapping ELF load segments are not supported")
        previous_end = segment["address"] + segment["memory_size"]

    if entry >= MEMORY_SIZE:
        raise BuildError("ELF entry 0x{:08x} is outside 1 MiB memory".format(entry))
    if not any(
        segment["address"] <= entry < segment["address"] + segment["memory_size"]
        and segment["flags"] & PF_X for segment in segments
    ):
        raise BuildError("ELF entry 0x{:08x} is not in an executable segment".format(entry))

    return {"entry": entry, "flags": flags, "segments": segments}


def find_halt(elf_info):
    for segment in elf_info["segments"]:
        if not (segment["flags"] & PF_X):
            continue
        data = segment["data"]
        start = 0
        while True:
            offset = data.find(HALT_BYTES, start)
            if offset < 0:
                break
            address = segment["address"] + offset
            if address % 4 == 0:
                return address
            start = offset + 1
    return None


def write_image(image_path, elf_info):
    segments = [item for item in elf_info["segments"] if item["file_size"]]
    with open(image_path, "w") as stream:
        for segment in segments:
            stream.write("@{:08X}\n".format(segment["address"]))
            data = segment["data"]
            for offset in range(0, len(data), 16):
                stream.write("{}\n".format(" ".join(
                    "{:02X}".format(value) for value in data[offset:offset + 16])))


def write_manifest(manifest_path, args, paths, elf_info, halt_address):
    output = {
        "format": "verilog-cpu-image-v1",
        "arch": args.arch,
        "abi": args.abi,
        "entry": "0x{:08x}".format(elf_info["entry"]),
        "memory_size": MEMORY_SIZE,
        "rom_size": ROM_SIZE,
        "halt_instruction": "0x{:08x}".format(HALT_WORD),
        "halt_address": ("0x{:08x}".format(halt_address)
                         if halt_address is not None else None),
        "segments": [
            {
                "address": "0x{:08x}".format(item["address"]),
                "file_size": item["file_size"],
                "memory_size": item["memory_size"],
                "flags": "{}{}{}".format(
                    "r" if item["flags"] & 4 else "",
                    "w" if item["flags"] & 2 else "",
                    "x" if item["flags"] & 1 else ""),
            }
            for item in elf_info["segments"]
        ],
        "files": {key: os.path.basename(value) for key, value in paths.items()},
    }
    with open(manifest_path, "w") as stream:
        json.dump(output, stream, indent=2, sort_keys=True)
        stream.write("\n")


def default_paths(args, source):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    stem = os.path.splitext(os.path.basename(source))[0]
    out_dir = args.out_dir
    if out_dir is None:
        out_dir = os.path.join(root, "build", "images", stem + "-" + args.arch)
    out_dir = os.path.abspath(out_dir)
    return out_dir, stem


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    source = os.path.abspath(args.source)
    if not os.path.isfile(source):
        raise BuildError("source file does not exist: {}".format(source))
    if args.abi != "ilp32":
        raise BuildError("only the RV32 ilp32 ABI is supported")

    script_dir = os.path.dirname(os.path.abspath(__file__))
    startup = os.path.abspath(args.startup or os.path.join(script_dir, "startup.S"))
    linker = os.path.abspath(args.linker or os.path.join(script_dir, "link.ld"))
    runtime = os.path.abspath(args.runtime or os.path.join(script_dir, "runtime.c"))
    for path in (startup, linker, runtime):
        if not os.path.isfile(path):
            raise BuildError("required build input does not exist: {}".format(path))

    out_dir, stem = default_paths(args, source)
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)

    prefix = os.environ.get("RISCV_PREFIX", "riscv64-elf-")
    cc = command_path(args.cc, "RISCV_GCC", prefix + "gcc")
    objcopy = command_path(args.objcopy, "RISCV_OBJCOPY", prefix + "objcopy")
    objdump = command_path(args.objdump, "RISCV_OBJDUMP", prefix + "objdump")
    readelf = command_path(args.readelf, "RISCV_READELF", prefix + "readelf")

    c_object = os.path.join(out_dir, stem + ".o")
    startup_object = os.path.join(out_dir, "startup.o")
    runtime_object = os.path.join(out_dir, "runtime.o")
    elf = os.path.join(out_dir, stem + ".elf")
    raw_binary = os.path.join(out_dir, stem + ".bin")
    image = os.path.join(out_dir, stem + ".image")
    dump = os.path.join(out_dir, stem + ".dump")
    map_file = os.path.join(out_dir, stem + ".map")
    manifest = os.path.join(out_dir, stem + ".json")

    common = [
        "-march=" + args.arch,
        "-mabi=" + args.abi,
        "-mno-relax",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-stack-protector",
        "-fno-pic",
        "-fno-pie",
        "-fno-asynchronous-unwind-tables",
        "-fno-unwind-tables",
        "-fno-tree-loop-distribute-patterns",
        "-ffunction-sections",
        "-fdata-sections",
    ]
    include_flags = []
    for include in [os.path.dirname(source)] + args.includes:
        include_flags.extend(["-I", os.path.abspath(include)])

    # Stage 1a: C source -> object.
    run([cc] + common + [args.opt, "-c", source, "-o", c_object] +
        include_flags + args.cflag)
    # Stage 1b: startup assembly -> object.
    run([cc] + common + ["-c", startup, "-o", startup_object])
    # Stage 1c: minimal runtime -> object.
    run([cc] + common + [args.opt, "-c", runtime, "-o", runtime_object])

    # Stage 2: objects -> ELF.  libgcc supplies compiler helper routines when
    # an RV32I program uses operations that are not in the selected ISA.
    run([cc] + common + ["-nostdlib", "-nostartfiles", "-nodefaultlibs",
                         "-Wl,-T," + linker,
                         "-Wl,-Map," + map_file,
                         "-Wl,--gc-sections",
                         "-Wl,--build-id=none",
                         "-Wl,--no-warn-rwx-segments",
                         startup_object, c_object, runtime_object,
                         "-lgcc", "-o", elf])

    # Stage 3a: retain a conventional raw binary as well as the sparse image.
    run([objcopy, "-O", "binary", "--gap-fill", "0", elf, raw_binary])
    with open(dump, "w") as stream:
        run([objdump, "-d", elf], stdout=stream)
    # Keep the toolchain metadata in the build log and make it easy to inspect.
    readelf_output = os.path.join(out_dir, stem + ".readelf")
    with open(readelf_output, "w") as stream:
        run([readelf, "-h", "-l", "-S", elf], stdout=stream)

    elf_info = read_elf(elf)
    halt_address = find_halt(elf_info)
    if elf_info["entry"] != 0:
        raise BuildError("entry must be 0 for the Verilog CPU, got 0x{:08x}".format(
            elf_info["entry"]))
    if halt_address is None:
        raise BuildError("executable image does not contain HALT 0x{:08x}".format(
            HALT_WORD))
    write_image(image, elf_info)
    paths = {
        "object": c_object,
        "startup_object": startup_object,
        "runtime_object": runtime_object,
        "elf": elf,
        "binary": raw_binary,
        "image": image,
        "dump": dump,
        "map": map_file,
        "readelf": readelf_output,
        "manifest": manifest,
    }
    write_manifest(manifest, args, paths, elf_info, halt_address)

    load_bytes = sum(item["file_size"] for item in elf_info["segments"])
    memory_high_water = max(
        (item["address"] + item["memory_size"] for item in elf_info["segments"]),
        default=0)
    print("generated {}".format(image))
    print("  entry: 0x{:08x}".format(elf_info["entry"]))
    print("  halt:  0x{:08x}".format(halt_address))
    print("  load bytes: {}".format(load_bytes))
    print("  memory high-water: 0x{:08x} / 0x{:08x}".format(
        memory_high_water, MEMORY_SIZE))

    if not args.keep_intermediates:
        for path in (c_object, startup_object, runtime_object, dump,
                     map_file, readelf_output):
            if os.path.exists(path):
                os.remove(path)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as exc:
        print("error: {}".format(exc), file=sys.stderr)
        sys.exit(2)
