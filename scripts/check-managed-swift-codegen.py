#!/usr/bin/env python3
"""Check the compiler-owned Swift boundary used by the managed-value prototype."""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def body(ir, name):
    match = re.search(r"^define[^\n]*@" + re.escape(name) + r"\([^\n]*\).*?^}", ir, re.M | re.S)
    if match is None:
        raise RuntimeError(f"Missing adapter: {name}")
    return match[0]


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/managed-swift-codegen"
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
                  "-O", "-target", target, "-sdk", sdk]
        run(*common, "-enable-library-evolution", "-module-name", "ManagedSwiftFixtures",
            "-emit-module", str(root / "Tests/ManagedSwiftFixtures/Values.swift"),
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        ir_path = directory / "adapters.ll"
        run(*common, "-module-name", "ManagedSwiftAdapters", "-I", str(directory),
            "-emit-ir", str(root / "Tests/ManagedSwiftAdapters/Adapters.swift"), "-o", str(ir_path))
        ir = ir_path.read_text()
        calls = {}
        for name in ["ABIManagedRecordTransform", "ABIOptionalValueTransform", "ABIResilientRecordTransform"]:
            adapter = body(ir, name)
            calls[name] = [line.strip() for line in adapter.splitlines()
                           if "call swiftcc" in line and "Fixtures" in line and "transform" in line]
            if len(calls[name]) != 1:
                raise RuntimeError(f"{target}: expected one native Swift transform call in {name}")
        # These fixtures intentionally contrast known frozen/Optional lowering
        # with a cross-module resilient signature. Do not derive either from size.
        if any("sret(" in calls[name][0] for name in ["ABIManagedRecordTransform", "ABIOptionalValueTransform"]):
            raise RuntimeError(f"{target}: re-evaluate the fixture's direct result lowering")
        if "sret(" not in calls["ABIResilientRecordTransform"][0]:
            raise RuntimeError(f"{target}: resilient fixture lost its indirect result boundary")
        resilient = body(ir, "ABIResilientRecordTransform")
        for operation in ["InitializeWithCopy", "InitializeWithTake", "Destroy"]:
            if operation not in resilient:
                raise RuntimeError(f"{target}: missing resilient value operation {operation}")
        reports.append({"target": target, "calls": calls})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
