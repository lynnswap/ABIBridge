#!/usr/bin/env python3
"""Record the compiler-owned generic metadata and conformance call boundary."""

import json
from pathlib import Path
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-generic-codegen"
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
            str(root / "Tests/ManagedSwiftFixtures/Generics.swift"),
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        adapter = [*common, "-module-name", "ManagedSwiftAdapters", "-I", str(directory),
                   str(root / "Tests/ManagedSwiftAdapters/GenericAdapters.swift")]
        ir_path, sil_path = directory / "generics.ll", directory / "generics.sil"
        run(*adapter, "-emit-ir", "-o", str(ir_path))
        run(*adapter, "-emit-sil", "-o", str(sil_path))
        ir, sil = ir_path.read_text(), sil_path.read_text()
        calls = {}
        for name in ["GenericRecordVMa", "makeGenericRecord", "measureGenericRecord"]:
            lines = [line.strip() for line in ir.splitlines() if "call swiftcc" in line and name in line]
            if not lines or any("ptr %Value, ptr %Value.GenericMetric" not in line for line in lines):
                raise RuntimeError(f"{target}: missing metadata and witness arguments for {name}")
            calls[name] = lines
        if "sret(%swift.opaque)" not in calls["makeGenericRecord"][0]:
            raise RuntimeError(f"{target}: generic result lost its indirect storage contract")
        if "open_existential_metatype" not in sil or "checked_cast_br" not in sil:
            raise RuntimeError(f"{target}: missing existing-conformance cast and metatype opening")
        for operation in ["InitializeWithTake", "Destroy"]:
            if operation not in ir:
                raise RuntimeError(f"{target}: missing generic value operation {operation}")
        reports.append({"target": target, "calls": calls})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
