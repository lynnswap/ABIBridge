#!/usr/bin/env python3
"""Compare compiler-generated calls with the Swift trampoline, without executing them."""

import argparse
import json
from pathlib import Path
import re
import struct
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def header(path):
    magic, cpu_type, cpu_subtype = struct.unpack("<III", path.read_bytes()[:12])
    if magic != 0xFEEDFACF:
        raise RuntimeError(f"Expected a thin 64-bit Mach-O object: {path}")
    return cpu_type, cpu_subtype


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def function_body(listing, name):
    lines = listing.splitlines()
    start = lines.index(f"_{name}:") + 1
    end = next((index for index in range(start, len(lines)) if lines[index].endswith(":")), len(lines))
    return "\n".join(lines[start:end])


def virtual_table_probe(common, root, output, arch, authenticated, expected):
    source = root / "Tests/ArchitectureValidation/VirtualTableCompilerProbe.cpp"
    assembly = output / f"{arch}-virtual-tables.s"
    object_file = assembly.with_suffix(".o")
    options = ["-std=c++20", "-O2", f"-DEXPECT_PTRAUTH={int(authenticated)}"]
    run(*common, *options, "-S", str(source), "-o", str(assembly))
    run(*common, *options, "-c", str(source), "-o", str(object_file))
    require(header(object_file) == (0x0100000C, expected), f"Unexpected virtual-table CPU subtype for {arch}")
    text = assembly.read_text()
    schemas = {}
    for name in ["PrimaryVptr", "SecondaryVptr", "PrimarySlot", "SecondarySlot", "CovariantSlot"]:
        value = re.search(rf"^_ABICompiler{name}:\s*\n\s*\.quad\s+(0x[0-9a-fA-F]+|\d+)", text, re.M)
        require(value is not None, f"Missing compiler discriminator {name} for {arch}")
        schemas[name] = int(value[1], 0)
    if authenticated:
        for name in ["Primary", "Secondary"]:
            body = re.search(rf"^_ABICompiler{name}Table:[^\n]*\n(.*?)\.cfi_endproc", text, re.M | re.S)
            require(body is not None and re.search(r"\bautda\b", body[1]), f"Missing compiler vptr authentication for {arch}")
            salts = re.findall(r"\bmovk\s+x\d+,\s*#(0x[0-9a-fA-F]+|\d+),\s*lsl\s*#48", body[1])
            require(schemas[name + "Vptr"] in [int(value, 0) for value in salts], f"Wrong inherited vptr schema for {arch}")
        entries = [
            (r"__ZNK9ABIVTable7Derived5valueEi", "PrimarySlot"),
            (r"__ZThn\d+_NK9ABIVTable7Derived8adjustedEi", "SecondarySlot"),
            (r"__ZTchn\d+_h\d+_N9ABIVTable7Derived8identityEv", "CovariantSlot"),
        ]
        for symbol, name in entries:
            require(re.search(rf"\.quad\s+{symbol}@AUTH\(ia,{schemas[name]},addr\)", text) is not None,
                    f"Wrong introducing-declaration schema for {name} on {arch}")
    else:
        require(all(value == 0 for value in schemas.values()) and "@AUTH(" not in text,
                "Unexpected authentication in arm64 virtual tables")
    return schemas


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architectures", nargs="+", choices=["arm64", "arm64e", "arm64e.x1"],
                        default=["arm64", "arm64e"])
    parser.add_argument("--output", type=Path, default=root / ".build/architecture-codegen")
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").strip()
    reports = []
    for arch in arguments.architectures:
        compiler = arguments.output / f"{arch}-compiler.o"
        trampoline = arguments.output / f"{arch}-trampoline.o"
        common = ["xcrun", "--sdk", "iphoneos", "clang", "-target", f"{arch}-apple-ios18.4", "-isysroot", sdk]
        authenticated = arch != "arm64"
        run(*common, "-std=c11", "-O2", f"-DEXPECT_PTRAUTH={int(authenticated)}", "-c",
            str(root / "Tests/ArchitectureValidation/CompilerProbe.c"), "-o", str(compiler))
        run(*common, "-c", str(root / "Sources/ABIBridgeCore/SwiftCall.S"), "-o", str(trampoline))
        expected = {"arm64": 0, "arm64e": 0x80000002, "arm64e.x1": 0x8000000C}[arch]
        for path in [compiler, trampoline]:
            require(header(path) == (0x0100000C, expected), f"Unexpected raw CPU type/subtype in {path}")
        listings = {}
        for name, path in [("compiler", compiler), ("trampoline", trampoline)]:
            listing = run("xcrun", "otool", "-tvV", str(path))
            path.with_suffix(".asm").write_text(listing)
            listings[name] = listing
            has_authenticated_call = re.search(r"\bblraa[z]?\b", listing) is not None
            require(has_authenticated_call == authenticated, f"Wrong call authentication in {path}")
            if authenticated:
                require(re.search(r"\bblr\b", listing) is None, f"Unauthenticated indirect call in {path}")
        typed = function_body(listings["compiler"], "compilerAdvance")
        integer = function_body(listings["compiler"], "compilerAdvanceInteger")
        typed_operation = "addpt" if arch == "arm64e.x1" else "add"
        require(re.search(rf"\b{typed_operation}\s+x\d+, x0, x1\b", typed) is not None,
                f"Unexpected compilerAdvance arithmetic for {arch}")
        require(re.search(r"\badd\s+x\d+, (?:x0, x1|x1, x0)\b", integer) is not None
                and re.search(r"\baddpt\b", integer) is None,
                f"Unexpected compilerAdvanceInteger arithmetic for {arch}")
        schemas = virtual_table_probe(common, root, arguments.output, arch, authenticated, expected)
        reports.append({"architecture": arch, "cpuType": "0x0100000c", "rawCPUSubtype": f"0x{expected:08x}",
                        "authenticatedCalls": authenticated, "checkedPointerArithmetic": arch == "arm64e.x1",
                        "virtualTableDiscriminators": schemas})
    result = {"compiler": run("xcrun", "clang", "--version").splitlines()[0], "runtimeTested": False, "objects": reports}
    (arguments.output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
