#!/usr/bin/env python3
"""Build separate compiled Swift provider/caller frameworks for import validation."""
import argparse
from pathlib import Path
import plistlib
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk", choices=["iphoneos", "macosx"], default="iphoneos")
    parser.add_argument("--architecture", choices=["arm64", "arm64e", "arm64e.x1"], default="arm64e")
    parser.add_argument("--sign", help="Optional codesigning identity for the generated frameworks")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    modules = output / "Modules"
    modules.mkdir(parents=True, exist_ok=True)
    sources = root / "Tests/ArchitectureValidation/Sources"
    sdk = subprocess.check_output(["xcrun", "--sdk", args.sdk, "--show-sdk-path"], text=True).strip()
    deployment = "ios18.4" if args.sdk == "iphoneos" else "macos15.4"
    common = ["xcrun", "--sdk", args.sdk, "swiftc", "-target", args.architecture + "-apple-" + deployment,
              "-sdk", sdk, "-swift-version", "6", "-O", "-parse-as-library", "-emit-library"]
    provider = None
    caller = output / "Caller.swift"
    caller.write_text((sources / "SwiftReplacementCaller/Caller.swift").read_text().replace("SwiftReplacementFixtures", "SwiftImportProvider"))
    for name in ["SwiftImportProvider", "SwiftImportCaller", "SwiftImportCallerControl"]:
        framework = output / (name + ".framework")
        framework.mkdir(exist_ok=True)
        binary = framework / name
        source = sources / "SwiftReplacementFixtures/Provider.swift" if provider is None else caller
        command = common + ["-module-name", name, str(source), "-o", str(binary),
                            "-Xlinker", "-install_name", "-Xlinker", "@rpath/" + name + ".framework/" + name]
        if provider is None:
            command += ["-emit-module", "-emit-module-path", str(modules / (name + ".swiftmodule"))]
        else:
            command += ["-I", str(modules), str(provider)]
        if name.endswith("Control"):
            command += ["-Xlinker", "-no_data_const"]
        subprocess.run(command, check=True)
        magic, cpu, subtype = struct.unpack("<III", binary.read_bytes()[:12])
        expected = {"arm64": 0, "arm64e": 0x80000002, "arm64e.x1": 0x8000000c}[args.architecture]
        if (magic, cpu, subtype) != (0xfeedfacf, 0x0100000c, expected):
            raise RuntimeError("Unexpected architecture in " + str(binary))
        (framework / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.abibridge.fixtures." + name, "CFBundleName": name,
            "CFBundleExecutable": name, "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "18.4" if args.sdk == "iphoneos" else "15.4",
            "CFBundleSupportedPlatforms": ["iPhoneOS" if args.sdk == "iphoneos" else "MacOSX"]
        }))
        if args.sign:
            subprocess.run(["codesign", "--force", "--sign", args.sign, str(framework)], check=True)
        print(binary)
        if provider is None:
            provider = binary


if __name__ == "__main__":
    main()
