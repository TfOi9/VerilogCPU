#!/usr/bin/env bash
set -u

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
sora_dir=${SORA_DIR:-"$repo_dir/../SORA"}
asap7_dir=${ASAP7_DIR:-"$repo_dir/third_party/asap7"}
failed=0

pass() {
    printf 'PASS %-12s %s\n' "$1" "$2"
}

warn() {
    printf 'WARN %-12s %s\n' "$1" "$2"
}

fail() {
    printf 'FAIL %-12s %s\n' "$1" "$2"
    failed=1
}

check_command() {
    local name=$1
    local command_name=$2
    local path

    path=$(command -v "$command_name" 2>/dev/null || true)
    if [[ -n "$path" ]]; then
        pass "$name" "$path"
    else
        fail "$name" "command not found: $command_name"
    fi
}

check_command git git
check_command make make
check_command cmake cmake
check_command ctest ctest
check_command g++ g++-16
check_command python /opt/homebrew/bin/python3
check_command riscv-gcc riscv64-elf-gcc
check_command riscv-objdump riscv64-elf-objdump
check_command iverilog iverilog
check_command verilator verilator
check_command yosys yosys
check_command gtkwave gtkwave
check_command timeout timeout
check_command archive 7z

if [[ -x /opt/homebrew/bin/python3 ]]; then
    pass python-version "$(/opt/homebrew/bin/python3 --version 2>&1)"
else
    fail python-version "Homebrew Python is unavailable"
fi

if command -v riscv64-elf-gcc >/dev/null 2>&1; then
    multilib=$(riscv64-elf-gcc -print-multi-lib 2>/dev/null || true)
    if [[ "$multilib" == *"rv32i/ilp32"* ]]; then
        pass rv32i "rv32i/ilp32 multilib"
    else
        fail rv32i "rv32i/ilp32 multilib is unavailable"
    fi
    if [[ "$multilib" == *"rv32im/ilp32"* ]]; then
        pass rv32im "rv32im/ilp32 multilib"
    else
        fail rv32im "rv32im/ilp32 multilib is unavailable"
    fi
fi

if [[ -d "$sora_dir" && -f "$sora_dir/CMakeLists.txt" ]]; then
    pass sora "reference repository: $sora_dir"
else
    fail sora "reference repository is unavailable: $sora_dir"
fi

if [[ -d "$asap7_dir" ]]; then
    pass asap7 "PDK directory: $asap7_dir"
else
    warn asap7 "PDK directory is not present yet: $asap7_dir"
fi

if [[ "$failed" -ne 0 ]]; then
    printf 'Environment check failed.\n' >&2
    exit 1
fi

printf 'Environment check passed.\n'
