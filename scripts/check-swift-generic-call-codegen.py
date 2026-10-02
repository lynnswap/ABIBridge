#!/usr/bin/env python3
"""Verify declaration-level generic calls and resilient borrowed callbacks."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def body(ir, name):
    match = re.search(r'^define [^\n]*' + name + r'[^\n]*\{.*?^}', ir, re.M | re.S)
    require(match, f"Missing compiler fixture: {name}")
    return match[0]


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-generic-call-codegen"
    targets = []
    for target, sdk_name in [
        ("arm64-apple-macos15.4", "macosx"),
        ("x86_64-apple-macos15.4", "macosx"),
        ("arm64e-apple-ios18.4", "iphoneos"),
        ("arm64_32-apple-watchos11.4", "watchos"),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone", "-target", target, "-sdk", sdk]
        provider = root / "Tests/ManagedSwiftFixtures"
        run(*common, "-enable-library-evolution", "-module-name", "ManagedSwiftFixtures", "-emit-module",
            str(provider / "RuntimeValues.swift"), str(provider / "GenericCalls.swift"),
            str(provider / "Values.swift"), str(provider / "ExplicitValues.swift"),
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        source = root / "Tests/ManagedSwiftAdapters/GenericCallAdapters.swift"
        ir_path = directory / "calls.ll"
        sil_path = directory / "calls.sil"
        adapter = [*common, "-module-name", "InvocationEvidence", "-I", str(directory), str(source)]
        run(*adapter, "-emit-ir", "-o", str(ir_path))
        run(*adapter, "-emit-sil", "-o", str(sil_path))
        ir, sil = ir_path.read_text(), sil_path.read_text()
        generic = next(line.strip() for line in ir.splitlines() if line.startswith("declare ") and "runGeneric" in line)
        require("sret(" in generic and generic.count("ptr") == 4,
                f"{target}: generic call needs indirect result, closure pair and one metadata pointer")
        callback = next(line.strip() for line in body(ir, "probeGenericCallback").splitlines()
                        if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc void" in callback and "sret(" in callback,
                f"{target}: generic callback must initialize indirect output with its capture context")
        borrowed = next(line.strip() for line in body(ir, "probeBorrowedCallback").splitlines()
                        if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc void" in borrowed and "sret(" not in borrowed and "ptr noalias" in borrowed,
                f"{target}: resilient callback must borrow one indirect input and return Void")
        tuple_callback = next(line.strip() for line in body(ir, "probeGenericTupleCallback").splitlines()
                              if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc i16" in tuple_callback and "sret(" not in tuple_callback,
                f"{target}: a generic tuple mixes a formal output pointer with coalesced direct results")
        concrete_tuple = next(line.strip() for line in body(ir, "probeConcreteTupleCallback").splitlines()
                              if "call swiftcc" in line and "swiftself" in line)
        pack_callback = next(line.strip() for line in body(ir, "probeGenericPackCallback").splitlines()
                             if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc void" in pack_callback and "sret(" in pack_callback,
                f"{target}: a pack callback receives input and output address vectors")
        large_callback = next(line.strip() for line in body(ir, "probeLargeFixedCallback").splitlines()
                              if "call swiftcc" in line and "swiftself" in line)
        for name in ["probeBorrowedGetter", "probeBorrowedMethod"]:
            require("swiftself" in body(ir, name), f"{target}: member needs indirect self context")
        require("@out Value" in sil and "@in_guaranteed RuntimeRecord" in sil,
                f"{target}: missing formal generic/resilient SIL conventions")
        if target.startswith("arm64e"):
            require('"ptrauth"(i32 0, i64 55683)' in large_callback, "Large fixed callback authentication changed")
            require('"ptrauth"(i32 0, i64 47754)' in pack_callback, "Generic pack callback authentication changed")
            require('"ptrauth"(i32 0, i64 8528)' in tuple_callback, "Generic tuple callback authentication changed")
            require('"ptrauth"(i32 0, i64 3335)' in concrete_tuple, "Concrete tuple callback authentication changed")
            require('"ptrauth"(i32 0, i64 29199)' in callback, "Generic result callback authentication changed")
            require('"ptrauth"(i32 0, i64 18589)' in borrowed, "Borrowed value callback authentication changed")
        targets.append({"target": target, "genericCall": generic, "genericCallback": callback,
                        "borrowedCallback": borrowed, "tupleCallback": tuple_callback, "concreteTupleCallback": concrete_tuple,
                        "packCallback": pack_callback, "largeFixedCallback": large_callback})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(), "runtimeTested": False, "targets": targets}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
