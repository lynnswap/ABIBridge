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


def swift_replacement_probe(root, output, arch, sdk, authenticated, expected):
    directory = output / (arch + "-swift-replacement")
    directory.mkdir(exist_ok=True)
    sources = root / "Tests/ArchitectureValidation/Sources"
    provider = sources / "SwiftReplacementFixtures/Provider.swift"
    caller = sources / "SwiftReplacementCaller/Caller.swift"
    common = ["xcrun", "swiftc", "-target", f"{arch}-apple-ios18.4", "-sdk", sdk,
              "-O", "-swift-version", "6", "-parse-as-library"]
    module = directory / "SwiftReplacementFixtures.swiftmodule"
    run(*common, "-module-name", "SwiftReplacementFixtures", "-emit-module", str(provider), "-o", str(module))
    provider_ir = directory / "provider.ll"
    caller_ir = directory / "caller.ll"
    object_file = directory / "provider.o"
    run(*common, "-module-name", "SwiftReplacementFixtures", "-emit-ir", str(provider), "-o", str(provider_ir))
    run(*common, "-module-name", "SwiftReplacementFixtures", "-c", str(provider), "-o", str(object_file))
    run(*common, "-module-name", "SwiftReplacementCaller", "-I", str(directory), "-emit-ir", str(caller), "-o", str(caller_ir))
    require(header(object_file) == (0x0100000C, expected), f"Unexpected Swift fixture CPU subtype for {arch}")
    definitions, calls = provider_ir.read_text(), caller_ir.read_text()
    methods = re.findall(r'%swift.method_descriptor \{ i32 (-?\d+), i32 trunc \(i64 sub \(i64 ptrtoint \(ptr @"([^"]+)"', definitions)
    method_flags = {symbol: int(flags) & 0xffffffff for flags, symbol in methods}
    demangled = dict(zip(method_flags, run("xcrun", "swift-demangle", "--compact", *method_flags).splitlines()))
    functions = re.findall(r'^define[^\n]*@"([^"\n]+)"[^\n]*\{\n(.*?)^\}', calls, re.M | re.S)
    names = run("xcrun", "swift-demangle", "--compact", *(name for name, _ in functions)).splitlines()
    bodies = dict(zip(names, (body for _, body in functions)))
    def oracle_body(name):
        matches = [body for declaration, body in bodies.items() if declaration.startswith("SwiftReplacementCaller." + name + "(")]
        require(len(matches) == 1, f"Expected one compiled oracle {name}")
        return matches[0]
    schemas = {}
    for method, oracle in [("scalar", "classScalar"), ("text", "classText"), ("payload", "classPayload")]:
        candidates = [(symbol, flags) for symbol, flags in method_flags.items()
                      if ".ReplacementRenderer." + method + "(" in demangled[symbol]]
        require(len(candidates) == 1, f"Expected one Swift method descriptor for {method} on {arch}")
        symbol, flags = candidates[0]
        require(flags & 0x7f == 0x10, f"Unexpected Swift method flags for {method}")
        body = oracle_body(oracle)
        require("swiftself" in body, f"Missing Swift receiver convention in {oracle}")
        offset = re.search(r'getelementptr inbounds (?:nuw )?i8, ptr .*?, i64 (\d+)\b', body)
        require(offset is not None, f"Missing Swift metadata slot in {oracle}")
        discriminator = flags >> 16
        if authenticated:
            schema = re.search(r'^@"' + re.escape(symbol) + r'\.ptrauth" = [^\n]*i32 0, i64 ptrtoint [^\n]*, i64 (\d+) \}, section "llvm.ptrauth"', definitions, re.M)
            require(schema is not None and int(schema[1]) == discriminator, f"Swift metadata/descriptor authentication differs for {method}")
            require(re.search(r'@llvm.ptrauth.blend\(i64 .*?, i64 ' + str(discriminator) + r'\)', body) is not None
                    and '"ptrauth"(i32 0,' in body, f"Swift caller does not authenticate {oracle} with the descriptor schema")
        else:
            require('"ptrauth"' not in body, f"Unexpected signed Swift call in {oracle}")
        schemas[oracle] = {"offset": int(offset[1]), "discriminator": discriminator, "addressDiversity": authenticated}
    final = oracle_body("classFinal")
    require(re.search(r'call swiftcc[^\n]*@"', final) is not None and "getelementptr" not in final,
            "Final Swift control stopped using a direct declaration")
    require(re.search(r'call swiftcc void @"[^"\n]+"\(ptr [^\n]*sret\(', oracle_body("importedPayload")) is not None,
            "Large Swift fixture result is no longer indirect")
    return schemas


def swift_callback_probe(common, root, output, arch, authenticated, expected):
    object_file = output / f"{arch}-swift-callback.o"
    run(*common, "-c", str(root / "Sources/ABIBridgeCore/SwiftCallback.S"), "-o", str(object_file))
    require(header(object_file) == (0x0100000C, expected), f"Unexpected callback CPU subtype for {arch}")
    symbols = {}
    for line in run("xcrun", "nm", "-n", str(object_file)).splitlines():
        match = re.match(r"^([0-9a-fA-F]+)\s+\w\s+(_ABISwiftCallback\w+)$", line)
        if match:
            symbols[match[2]] = int(match[1], 16)
    page_size = symbols["_ABISwiftCallbackAssembly"] - symbols["_ABISwiftCallbackCodePage"]
    require(page_size == 16384, f"Callback entries do not fill one maximum page on {arch}")
    listing = run("xcrun", "otool", "-tvV", str(object_file))
    object_file.with_suffix(".asm").write_text(listing)
    table = function_body(listing, "ABISwiftCallbackCodePage")
    branch = r"\bbraa\s+x16, x9\b" if authenticated else r"\bbr\s+x16\b"
    require(len(re.findall(branch, table)) == page_size // 32, f"Incorrect callback entry stride or branch for {arch}")
    require(len(re.findall(r"\bdmb\s+ishld\b", table)) == page_size // 32, f"Missing callback publication ordering for {arch}")
    entry = function_body(listing, "ABISwiftCallbackAssembly")
    require(re.search(r"\bstr\s+x20, \[sp, #(0xc8|200)\]", entry), f"Swift self register not captured for {arch}")
    require(re.search(r"\bstr\s+x8, \[sp, #(0xc0|192)\]", entry), f"Swift indirect-result register not captured for {arch}")
    require(("retab" in entry) == authenticated, f"Wrong callback return authentication for {arch}")
    return {"pageBytes": page_size, "entryStride": 32, "entries": page_size // 32}


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
        swift_schemas = swift_replacement_probe(root, arguments.output, arch, sdk, authenticated, expected)
        callbacks = swift_callback_probe(common, root, arguments.output, arch, authenticated, expected)
        reports.append({"architecture": arch, "cpuType": "0x0100000c", "rawCPUSubtype": f"0x{expected:08x}",
                        "authenticatedCalls": authenticated, "checkedPointerArithmetic": arch == "arm64e.x1",
                        "virtualTableDiscriminators": schemas, "swiftMethodSchemas": swift_schemas, "swiftCallbackEntries": callbacks})
    result = {"compiler": run("xcrun", "clang", "--version").splitlines()[0], "runtimeTested": False, "objects": reports}
    (arguments.output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
