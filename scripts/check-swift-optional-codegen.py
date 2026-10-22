#!/usr/bin/env python3
"""Check that Swift passes Optionals of scalars and pointers as their enum storage.

ABIBridge passes such an Optional as integer data over its storage, in
pointer-sized chunks (#438). This probe compiles the Optional fixtures and
fails when the compiler lowers one of them differently, or when a callback's
pointer-authentication discriminator differs from the one that
`SwiftGenericBindingTests` expects ABIBridge to compute.
"""

import json
from pathlib import Path
import re
import subprocess

# Parameter types of each fixture and of its callback, per target.
WIDE = {
    "incrementedOptionalUInt32": "i64",
    "negatedOptionalInt64": "i64, i8",
    "doubledOptional": "i64, i8",
    "invertedOptional": "i8",
    "advancedOptionalPointer": "i64",
    "describeOptionalScalars": "i64, i64, i8, i64, i8, i8, i64",
}
NARROW = {
    "incrementedOptionalUInt32": "i32, i8",
    "negatedOptionalInt64": "i32, i32, i8",
    "doubledOptional": "i32, i32, i8",
    "invertedOptional": "i8",
    "advancedOptionalPointer": "i32",
    "describeOptionalScalars": "i32, i8, i32, i32, i8, i32, i32, i8, i8, i32",
}
TARGETS = [
    ("arm64-apple-macos15.4", "macosx", WIDE),
    ("arm64e-apple-ios18.4", "iphoneos", WIDE),
    ("arm64_32-apple-watchos11.4", "watchos", NARROW),
]
# Fixtures that call a closure parameter: the fixture whose parameters the
# closure's match, and the discriminator with which arm64e authenticates it.
CALLBACKS = {
    # (UInt32?, Int64?, Double?, Bool?, UnsafeRawPointer?) -> String
    "visitOptionalScalars": ("describeOptionalScalars", 13547),
    # (UInt32?) -> ()
    "register": ("incrementedOptionalUInt32", 7278),
}


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def types(arguments):
    return ", ".join(part.split()[0] for part in arguments.split(", "))


def parameters(ir, name):
    found = re.search(r'^define swiftcc [^@]*@"[^"]*\d' + name + r'y[^"]*"\(([^)]*)\)', ir, re.M)
    if found is None:
        raise RuntimeError(f"missing {name}")
    return types(found[1])


def callback(ir, name):
    """The first call of a closure parameter, which has no symbol, in the
    definitions whose names contain name."""
    for body in re.findall(r'^define[^\n]*\d' + name + r'[^\n]*\{.*?^}', ir, re.M | re.S):
        for line in body.splitlines():
            call = re.search(r'call swiftcc [^@]*%\d+\((.*), ptr swiftself', line)
            if call:
                return line.strip(), types(call[1])
    raise RuntimeError(f"missing the callback call in {name}")


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-optional-codegen"
    output.mkdir(parents=True, exist_ok=True)
    reports = []
    for target, sdk_name, expected in TARGETS:
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        ir_path = output / f"{target}.ll"
        run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone", "-target", target,
            "-sdk", sdk, "-enable-library-evolution", "-module-name", "ManagedSwiftFixtures", "-emit-ir",
            str(root / "Tests/ManagedSwiftFixtures/Optionals.swift"), "-o", str(ir_path))
        ir = ir_path.read_text()
        lowered = {name: parameters(ir, name) for name in expected}
        for name, types in expected.items():
            if lowered[name] != types:
                raise RuntimeError(f"{target}: re-evaluate {name}: ({lowered[name]}), not ({types})")
        calls = {}
        for name, (fixture, discriminator) in CALLBACKS.items():
            call, passed = callback(ir, name)
            if passed != expected[fixture]:
                raise RuntimeError(f"{target}: re-evaluate the callback in {name}: {call}")
            if target.startswith("arm64e") and f'"ptrauth"(i32 0, i64 {discriminator})' not in call:
                raise RuntimeError(f"{target}: re-evaluate the discriminator in {name}: {call}")
            calls[name] = call
        reports.append({"target": target, "parameters": lowered, "callbacks": calls})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
