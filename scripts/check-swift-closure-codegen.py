#!/usr/bin/env python3
"""Record concrete and reabstracted Swift closure conventions without executing them."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def function(text, prefix, name):
    matches = re.finditer(r"^" + prefix + r"[^\n]*" + re.escape(name) + r"[^\n]*\{.*?^}", text, re.M | re.S)
    for match in matches:
        # @_cdecl emits a C thunk and a Swift body with related mangled names.
        if prefix == "sil" and "@convention(thin)" not in match[0].splitlines()[0]:
            continue
        return match[0]
    raise RuntimeError(f"Missing compiler function: {name}")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-closure-codegen"
    reports = []
    for target, sdk_name in [
        ("arm64-apple-macos15.4", "macosx"),
        ("x86_64-apple-macos15.4", "macosx"),
        ("arm64e-apple-ios18.4", "iphoneos"),
        ("arm64_32-apple-watchos11.4", "watchos"),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                  "-Onone", "-target", target, "-sdk", sdk]
        fixture = root / "Tests/ManagedSwiftFixtures"
        run(*common, "-enable-library-evolution", "-module-name", "ManagedSwiftFixtures",
            "-emit-module", str(fixture / "Values.swift"), str(fixture / "Closures.swift"),
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        source = root / "Tests/ManagedSwiftAdapters/ClosureAdapters.swift"
        adapter = [*common, "-module-name", "ManagedSwiftAdapters", "-I", str(directory), str(source)]
        sil_path, ir_path = directory / "closures.sil", directory / "closures.ll"
        run(*adapter, "-emit-sil", "-o", str(sil_path))
        run(*adapter, "-emit-ir", "-o", str(ir_path))
        sil, ir = sil_path.read_text(), ir_path.read_text()
        forward = function(sil, "sil", "concreteThroughGeneric")
        reverse = function(sil, "sil", "integerClosureApply")
        returned = function(sil, "sil", "integerClosureReturn")
        for name, value in [("concrete to generic", forward), ("generic to concrete", reverse),
                            ("returned to generic storage", returned)]:
            require("partial_apply" in value and "function_ref thunk" in value,
                    f"{target}: missing {name} reabstraction evidence")
        generic = function(sil, "sil", "invokeGenericClosure")
        require("@in_guaranteed" in generic and "@out Result" in generic,
                f"{target}: re-evaluate generic closure argument/result lowering")
        require("@noescape" in reverse, f"{target}: nonescaping fixture lost its contract")
        require("@owned @callee_guaranteed" in returned, f"{target}: missing owned closure result")

        apply = next(line for line in ir.splitlines() if line.startswith("declare ") and "applyIntegerClosure" in line)
        factory = next(line for line in ir.splitlines() if line.startswith("declare ") and "makeIntegerClosure" in line)
        require("{ ptr, ptr }" in factory, f"{target}: re-evaluate concrete closure result representation")
        invocation = function(ir, "define", "invokeGenericClosure")
        calls = [line.strip() for line in invocation.splitlines() if "call swiftcc" in line and "swiftself" in line]
        require(len(calls) == 1 and "sret(" in calls[0],
                f"{target}: expected one indirect-result callback invocation with its hidden context")
        reports.append({"target": target, "nativeApply": apply, "nativeFactory": factory,
                        "genericInvocation": calls[0], "reabstractionDirections": 3})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
