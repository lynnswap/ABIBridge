#!/usr/bin/env python3
"""Check standard managed collection lowering against the Swift compiler."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-collection-codegen"
    reports = []
    for target, sdk_name, bits in [
        ("arm64-apple-macos15.4", "macosx", 64),
        ("x86_64-apple-macos15.4", "macosx", 64),
        ("arm64e-apple-ios18.4", "iphoneos", 64),
        ("arm64_32-apple-watchos11.4", "watchos", 32),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        ir_path = directory / "collections.ll"
        run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
            "-whole-module-optimization", "-enable-library-evolution",
            "-module-name", "ManagedSwiftFixtures", "-target", target, "-sdk", sdk,
            "-emit-ir", str(root / "Tests/ManagedSwiftFixtures/Values.swift"),
            str(root / "Tests/ManagedSwiftFixtures/Collections.swift"), "-o", str(ir_path))
        ir = ir_path.read_text()
        word = f"i{bits}"
        string_words = 2 if bits == 64 else 3
        expected = [
            ("applyArrayClosure", "ptr", ["ptr"]),
            ("applyOptionalArrayClosure", word, [word]),
            ("applyOptionalStringClosure", "{ " + ", ".join([word] * string_words) + " }",
             [word] * string_words),
        ]
        calls = {}
        for name, result, arguments in expected:
            body = re.search(r'^define swiftcc[^\n]*' + name + r'y[^\n]*\{.*?^}', ir, re.M | re.S)
            if body is None:
                raise RuntimeError(f"{target}: missing {name}")
            lines = [line.strip() for line in body[0].splitlines()
                     if "call swiftcc" in line and "swiftself" in line]
            if len(lines) != 1:
                raise RuntimeError(f"{target}: expected one callback in {name}")
            call = re.search(r"call swiftcc (.*?) %[0-9]+\((.*?)\)", lines[0])
            if call is None or call[1] != result:
                raise RuntimeError(f"{target}: re-evaluate {name} result lowering: {lines[0]}")
            actual = [argument.split()[0] for argument in call[2].split(", ")]
            if actual != arguments + ["ptr"]:
                raise RuntimeError(f"{target}: re-evaluate {name} argument lowering: {lines[0]}")
            calls[name] = lines[0]
        reports.append({"target": target, "calls": calls})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
