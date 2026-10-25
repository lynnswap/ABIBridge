#!/usr/bin/env python3
"""Compile consumer/header and explicit backend-import contracts."""

from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    includes = [
        "-I", str(root / "Sources/ABIBridgeCore/include"),
        "-I", str(root / "Sources/ABIBridgeObjCXX/include"),
    ]
    checks = [
        ("C umbrella", "c", "", """
#include <ABIBridge/ABIBridge.h>
ABIValueType *prepare(ABIResolutionFailure **failure) {
    ABIPointerSlotResult effect = {0};
    (void)effect; (void)ABIAuthenticationUnsigned;
    return ABICreateScalarType(ABIValueInt32, failure);
}
""", None),
        ("C virtual entry feature", "c", "", """
#include <ABIBridge/VirtualEntries.h>
ABIVirtualEntryInfo slot;
""", None),
        ("C backend isolation", "c", "", """
#include <ABIBridge/ABIBridge.h>
ABISwiftCallInterface *backend;
""", "ABISwiftCallInterface"),
        ("C++ umbrella", "c++", "", """
#include <ABIBridge/ABIBridge.hpp>
using callable = abi_bridge::function<int(int)>;
using callback_layout = ABIValueType;
ABIPointerSlotResult effect{};
""", None),
        ("C++ backend isolation", "c++", "", """
#include <ABIBridge/ABIBridge.hpp>
abi_bridge::InvocationRuntime backend;
""", "InvocationRuntime"),
        ("Swift consumer module", "swift", "", """
import ABIBridgeCore
let create = ABICreateScalarType
let schema = ABIAuthenticationInstructionA
let effect = ABIPointerSlotResult()
""", None),
        ("Swift backend isolation", "swift", "", """
import ABIBridgeCore
let backend = ABICreateCCallInterface
""", "ABICreateCCallInterface"),
        ("Swift explicit backend", "swift", "", """
import ABIBridgeCore
import ABIBridgeCore.Backend
let backend = ABICreateCCallInterface
let metadata = ABISwiftGetValueLayout
""", None),
        ("Objective-C module isolation", "swift", "", """
import ABIBridgeObjCXX
let backend = ABIObjCPrepareInvocationPlan
""", "ABIObjCPrepareInvocationPlan"),
        ("Objective-C explicit backend", "swift", "", """
import ABIBridgeObjCXX
import ABIBridgeObjCXX.Backend
let backend = ABIObjCPrepareInvocationPlan
""", None),
    ]
    for language in ("objective-c", "objective-c++"):
        for ownership in ("arc", "no-arc"):
            header = "ABIBridge.hpp" if language.endswith("++") else "ABIBridge.h"
            objc_header = "ObjectiveCInvocation.hpp" if language.endswith("++") else "ObjectiveCInvocation.h"
            checks.append((f"{language} {ownership}", language, ownership, f"""
#import <ABIBridge/{header}>
#import <ABIBridge/{objc_header}>
NSErrorDomain domain(void) {{ return ABIObjCInvocationErrorDomain; }}
ABIValueType *layout(ABIResolutionFailure **failure) {{
    return ABICreateScalarType(ABIValueInt32, failure);
}}
""", None))

    with tempfile.TemporaryDirectory(prefix="abibridge-header-contracts-") as folder:
        temporary = Path(folder)
        for index, (label, language, ownership, source, expected_error) in enumerate(checks):
            suffix = ".swift" if language == "swift" else ".cpp" if language.endswith("++") else ".m" if language == "objective-c" else ".c"
            path = temporary / f"case-{index}{suffix}"
            path.write_text(source)
            if language == "swift":
                command = ["xcrun", "swiftc", "-swift-version", "6", "-typecheck", *includes, str(path)]
            else:
                compiler = "clang++" if language.endswith("++") else "clang"
                standard = "c++20" if language.endswith("++") else "c11"
                command = ["xcrun", compiler, "-x", language, f"-std={standard}", "-fsyntax-only", *includes]
                if ownership:
                    command.append("-fobjc-arc" if ownership == "arc" else "-fno-objc-arc")
                command.append(str(path))
            result = subprocess.run(command, capture_output=True, text=True)
            if expected_error is None:
                passed = result.returncode == 0
            else:
                passed = result.returncode != 0 and expected_error in result.stderr
            if not passed:
                print(f"FAILED: {label}")
                print(result.stdout + result.stderr)
                raise SystemExit(1)
            print(f"Passed: {label}")
    print(f"Native header contracts passed ({len(checks)} checks)")


if __name__ == "__main__":
    main()
