#!/usr/bin/env python3
"""Check explicit managed struct/enum lowering without assuming C aggregate ABI."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/explicit-swift-value-codegen"
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
        common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
                  "-target", target, "-sdk", sdk]
        run(*common, "-enable-library-evolution", "-module-name", "ManagedSwiftFixtures",
            "-emit-module", str(root / "Tests/ManagedSwiftFixtures/Values.swift"),
            str(root / "Tests/ManagedSwiftFixtures/ExplicitValues.swift"),
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        ir_path = directory / "values.ll"
        run(*common, "-module-name", "ExplicitValueProbe", "-I", str(directory),
            "-emit-ir", str(root / "Tests/ManagedSwiftAdapters/ExplicitValueAdapters.swift"),
            "-o", str(ir_path))
        ir = ir_path.read_text()
        calls = {}
        enum_result = "{ i32, i32, i8 }" if target.startswith("arm64_32") else "{ i64, i8 }"
        for name, result in [("probeVector", "{ ptr, double, double }"),
                             ("probeChoice", enum_result), ("probeLarge", "void")]:
            body = re.search(r'^define swiftcc[^\n]*' + name + r'y[^\n]*\{.*?^}', ir, re.M | re.S)
            if body is None:
                raise RuntimeError(f"{target}: missing {name}")
            lines = [line.strip() for line in body[0].splitlines()
                     if "call swiftcc" in line and "swiftself" in line]
            if len(lines) != 1 or f"call swiftcc {result} %" not in lines[0]:
                raise RuntimeError(f"{target}: re-evaluate {name} native lowering: {lines}")
            if name == "probeLarge":
                if "sret(" not in lines[0]:
                    raise RuntimeError(f"{target}: missing indirect large result")
                if target.startswith("arm64e") and '"ptrauth"(i32 0, i64 55683)' not in lines[0]:
                    raise RuntimeError(f"{target}: re-evaluate indirect closure discriminator")
            calls[name] = lines[0]
        reports.append({"target": target, "calls": calls})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
