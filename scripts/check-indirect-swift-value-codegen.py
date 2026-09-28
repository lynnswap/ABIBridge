#!/usr/bin/env python3
"""Check formally indirect values and generic nominal callback identities."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/indirect-swift-value-codegen"
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
            str(root / "Tests/ManagedSwiftFixtures/IndirectValues.swift"),
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        ir_path = directory / "indirect.ll"
        run(*common, "-module-name", "IndirectValueProbe", "-I", str(directory), "-emit-ir",
            str(root / "Tests/ManagedSwiftAdapters/IndirectValueAdapters.swift"), "-o", str(ir_path))
        ir = ir_path.read_text()
        calls = {}
        for name in ["probeResilient", "probeIntegerBox", "probeDoubleBox", "probeStringBox", "probeNested", "probeUnicode"]:
            body = re.search(r'^define swiftcc[^\n]*' + name + r'y[^\n]*\{.*?^}', ir, re.M | re.S)
            if body is None:
                raise RuntimeError(f"{target}: missing {name}")
            lines = [line.strip() for line in body[0].splitlines()
                     if "call swiftcc" in line and "swiftself" in line]
            if len(lines) != 1:
                raise RuntimeError(f"{target}: expected one native callback in {name}")
            calls[name] = lines[0]
        if "sret(" not in calls["probeResilient"] or "call swiftcc void" not in calls["probeResilient"]:
            raise RuntimeError(f"{target}: resilient value lost its indirect convention")
        if "call swiftcc i64" not in calls["probeIntegerBox"] or "call swiftcc double" not in calls["probeDoubleBox"]:
            raise RuntimeError(f"{target}: concrete generic substitutions lost their distinct lowering")
        if target.startswith("arm64e"):
            auth = {name: re.search(r'"ptrauth"\(i32 0, i64 (\d+)\)', call)[1] for name, call in calls.items()}
            if auth["probeResilient"] != "55683":
                raise RuntimeError("Resilient authentication must erase indirect formal types")
            if len({auth[name] for name in ["probeIntegerBox", "probeDoubleBox", "probeStringBox"]}) != 1:
                raise RuntimeError("Generic nominal authentication must ignore substitutions")
        reports.append({"target": target, "calls": calls})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
