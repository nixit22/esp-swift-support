# Copyright (c) 2026 Nicolas Christe
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

"""Builds a Swift package for an ESP-IDF project with SwiftPM.

Port of espswift's `internal build-package` (PackageBuild.swift): writes a
SwiftPM toolset file from the ESP-IDF build's C flags and sdkconfig, runs
`swift build` for Embedded Swift on RISC-V, and copies the static library.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

TRIPLE = "riscv32-none-none-eabi"

LOG_LEVELS = ["ERROR", "WARN", "INFO", "DEBUG", "VERBOSE"]


def expand(arguments):
    """Arguments with @response files (ESP-IDF 6.x toolchain/cflags) read."""
    for argument in arguments:
        if argument.startswith("@") and os.path.isfile(argument[1:]):
            with open(argument[1:]) as f:
                yield from expand(shlex.split(f.read()))
        else:
            yield argument


def c_flags(build, flags_source, implicit):
    with open(f"{build}/compile_commands.json") as f:
        commands = json.load(f)
    source = os.path.realpath(flags_source)
    entry = next((e for e in commands if os.path.realpath(e["file"]) == source), None)
    if entry is None:
        sys.exit(f"error: compile_commands.json has no compile command for {flags_source}")
    arguments = entry.get("arguments") or shlex.split(entry["command"])

    flags, march, mabi = [], None, "-mabi=ilp32"
    for argument in expand(arguments):
        if argument.startswith(("-I", "-D")):
            flags.append(argument)
        elif argument.startswith("-march="):
            # Espressif's own ISA extensions (_xesp...) aren't known to Clang.
            march = "_".join(p for p in argument.split("_") if not p.startswith("xesp"))
        elif argument.startswith("-mabi="):
            mabi = argument
    for path in implicit:
        flags += ["-isystem", path]
    return ([march] if march else []) + [mabi, "-fno-pic", "-fno-pie", "-ffunction-sections", "-fno-blocks"] + flags


GCC_TYPE_MACRO = re.compile(
    r"^#define (__(?:U?INT(?:_LEAST|_FAST)?(?:8|16|32|64)|U?INTMAX|U?INTPTR|SIZE|PTRDIFF|WINT)_TYPE__) (.+)$")


def gcc_type_flags(cc, arch_flags):
    """-U/-D pairs that give clang the integer types GCC defines for the target.

    ESP-IDF is built with GCC and clang compiles the C/C++ glue: if they disagree on a
    type, C++ symbols mangle differently and the glue cannot link to GCC-built libraries
    (riscv32-esp-elf: GCC's uint32_t is `long unsigned int`, clang's is `unsigned int`).
    """
    if not cc:
        return []
    out = subprocess.run([cc, *arch_flags, "-dM", "-E", "-x", "c", os.devnull],
                         capture_output=True, text=True, check=True).stdout
    flags = []
    for line in sorted(out.splitlines()):
        m = GCC_TYPE_MACRO.match(line)
        if m:
            flags += [f"-U{m.group(1)}", f"-D{m.group(1)}={m.group(2)}"]
    return flags


def cxx_flags(flags, implicit):
    """C++ options: the C ones, with the C++ compiler's own include folders
    instead of the C compiler's, and as esp_matter builds its C++ code."""
    kept, skip = [], False
    for i, flag in enumerate(flags):
        if skip:
            skip = False
        elif flag == "-isystem":
            skip = True
        else:
            kept.append(flag)
    for path in implicit:
        kept += ["-isystem", path]
    return kept + ["-fno-exceptions", "-fno-rtti"]


def swift_conditions(build):
    """-D CONFIG_<name> for each sdkconfig option that's on, and
    LOG_<LEVEL>_ENABLED from CONFIG_LOG_MAXIMUM_LEVEL (an integer)."""
    with open(f"{build}/config/sdkconfig.json") as f:
        settings = json.load(f)
    conditions = []
    for name in sorted(settings):
        if settings[name] is True:
            conditions += ["-D", f"CONFIG_{name}"]
    maximum = settings.get("LOG_MAXIMUM_LEVEL", 0)
    for level, name in enumerate(LOG_LEVELS, start=1):
        if isinstance(maximum, int) and maximum >= level:
            conditions += ["-D", f"LOG_{name}_ENABLED"]
    return conditions


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--build-folder", required=True)
    p.add_argument("--flags-source", required=True)
    p.add_argument("--package", required=True)
    p.add_argument("--product", required=True)
    p.add_argument("--swift-bin", required=True)
    p.add_argument("--cc", default="", help="GCC of the ESP-IDF build (its integer types are given to clang)")
    p.add_argument("--librarian", required=True, help="ELF archiver (llvm-ar)")
    p.add_argument("--output", required=True)
    p.add_argument("--implicit", default="", help="'|' separated C compiler include folders")
    p.add_argument("--implicit-cxx", default="", help="'|' separated C++ compiler include folders")
    a = p.parse_args()

    scratch = os.path.join(a.build_folder, "swift-build")
    os.makedirs(scratch, exist_ok=True)
    implicit = [x for x in a.implicit.split("|") if x]
    implicit_cxx = [x for x in a.implicit_cxx.split("|") if x]
    c = c_flags(a.build_folder, a.flags_source, implicit)
    c += gcc_type_flags(a.cc, [f for f in c if f.startswith(("-march=", "-mabi="))])

    toolset = {
        "schemaVersion": "1.0",
        "swiftCompiler": {"extraCLIOptions": [
            "-enable-experimental-feature", "Embedded", "-wmo", "-Osize", "-g",
            "-Xfrontend", "-function-sections",
            # One LLVM module per Swift module: `@used`/`@section` globals must be definitions
            # in the module that lists them (without it the compiler asserts, e.g. BME280).
            "-Xfrontend", "-enable-single-module-llvm-emission",
        ] + swift_conditions(a.build_folder)},
        "cCompiler": {"extraCLIOptions": c},
        "cxxCompiler": {"extraCLIOptions": cxx_flags(c, implicit_cxx)},
        # An ELF archiver: SwiftPM would otherwise use Xcode's libtool on macOS.
        "librarian": {"path": a.librarian},
    }
    toolset_path = os.path.join(scratch, "toolset.json")
    with open(toolset_path, "w") as f:
        json.dump(toolset, f, indent=2, sort_keys=True)

    command = [
        f"{a.swift_bin}/swift", "build",
        "--package-path", a.package,
        "--scratch-path", scratch,
        "--triple", TRIPLE,
        "--configuration", "release",
        "--toolset", toolset_path,
        "--disable-local-rpath",
        # Swift Build, the default since Swift 6.4, can't link ESP32 C code.
        "--build-system", "native",
        "--product", a.product,
    ]
    # ESP-IDF's environment puts its GCC/binutils toolchains in PATH
    # (riscv32-esp-elf, xtensa-esp-elf, esp32ulp-elf: folders with a plain
    # `ld`). SwiftPM links the package manifest for the host with the first
    # `ld` it finds, and those can't.
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join(
        [a.swift_bin] + [d for d in env.get("PATH", "").split(os.pathsep) if "-elf" not in d])
    if subprocess.call(command, env=env) != 0:
        sys.exit("error: building the Swift package failed")
    shutil.copyfile(f"{scratch}/{TRIPLE}/release/lib{a.product}.a", a.output)


if __name__ == "__main__":
    main()
