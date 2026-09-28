#!/usr/bin/env python3
"""Record native synchronous Swift error carriers and output-buffer conventions."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-error-codegen"
    reports = []
    names = ["untypedResult", "scalarErrorResult", "managedErrorResult", "largeErrorResult",
             "resilientErrorResult", "referenceErrorResult", "floatingErrorResult",
             "scalarErrorFloatingResult", "scalarErrorVoidResult", "bothIndirectResult"]
    indirect_errors = {"largeErrorResult", "resilientErrorResult", "floatingErrorResult", "bothIndirectResult"}
    for target, sdk_name, bits in [
        ("arm64-apple-macos15.4", "macosx", 64),
        ("x86_64-apple-macos15.4", "macosx", 64),
        ("arm64e-apple-ios18.4", "iphoneos", 64),
        ("arm64_32-apple-watchos11.4", "watchos", 32),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
                  "-target", target, "-sdk", sdk]
        fixture = [*common, "-enable-library-evolution", "-module-name", "ManagedSwiftFixtures",
                   str(root / "Tests/ManagedSwiftFixtures/Errors.swift")]
        run(*fixture, "-emit-module", "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        fixture_ir = directory / "errors.ll"
        run(*fixture, "-emit-ir", "-o", str(fixture_ir))
        ir_path = directory / "adapters.ll"
        run(*common, "-module-name", "ErrorProbe", "-I", str(directory), "-emit-ir",
            str(root / "Tests/ManagedSwiftAdapters/ErrorAdapters.swift"), "-o", str(ir_path))
        ir = ir_path.read_text()
        declarations = {}
        for name in names:
            lines = [line for line in ir.splitlines()
                     if line.startswith("declare swiftcc") and name in line and "Fixtures" in line]
            if len(lines) != 1 or "swifterror" not in lines[0]:
                raise RuntimeError(f"{target}: missing concrete error declaration {name}")
            declaration = lines[0]
            after_error_register = declaration.split("swifterror", 1)[1]
            has_error_buffer = ", ptr" in after_error_register
            if has_error_buffer != (name in indirect_errors):
                raise RuntimeError(f"{target}: re-evaluate {name} typed error storage: {declaration}")
            declarations[name] = declaration
        if "sret(" not in declarations["bothIndirectResult"]:
            raise RuntimeError(f"{target}: expected separate success and error output storage")
        if "{ double, i64 }" not in declarations["scalarErrorFloatingResult"]:
            raise RuntimeError(f"{target}: expected independent floating success and integer error carriers")
        if "swiftcc i64" not in declarations["scalarErrorVoidResult"]:
            raise RuntimeError(f"{target}: typed failure must survive a Void success result")
        provider = fixture_ir.read_text()
        if "@swift_allocError" not in provider or "@swift_willThrowTyped" not in provider:
            raise RuntimeError(f"{target}: missing boxed versus typed error evidence")
        if f"store ptr inttoptr (i{bits} 1 to ptr)" not in provider:
            raise RuntimeError(f"{target}: re-evaluate the typed failure indicator")
        reports.append({"target": target, "declarations": declarations})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
