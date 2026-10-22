#!/usr/bin/env python3
"""Check the compiler facts that inferred struct and enum conventions read.

ABIBridge infers a value's convention from its static value-witness flags and
from the symbols that only library evolution exports (#430). This probe
compiles one module with and without library evolution and fails when one of
those facts changes, so a new compiler fails CI instead of mislowering values:

- the addressable-for-dependencies bit (0x02000000) is clear for frozen
  values, set for resilient ones and for values that store a String, and
  clear for any value without library evolution that stores neither;
- a stored property of an opaque type that is not class-bound sets the
  addressable-for-dependencies bit and makes its struct pass by address,
  while a class-bound one does neither;
- a struct with an unowned reference to an Objective-C class is not
  bitwise-takable, while one with an unowned reference to a native Swift
  class is;
- resilient enums, and only those, export enum case symbols (WC);
- a stored property's descriptor has a stored component with library
  evolution and is trivial without it;
- on arm64e, a closure parameter that is passed indirectly hashes as
  `-indirect`, and generic arguments do not change a nominal type's hash;
- on arm64e, an element of a closure's tuple result hashes as `-indirect`
  only when it is address-only, whatever its size.

It also checks that the generated self-addressable declarations cover the
selected SDKs.
"""

import json
from pathlib import Path
import re
import subprocess

SOURCE = """
import Foundation
public final class Box {}
public final class BridgedBox: NSObject {}
@frozen public struct FrozenPoint { public var x: Double; public var y: Double }
public struct OpenPoint { public var x: Double; public var y: Double }
@frozen public struct FrozenLabel { public var text: String; public var n: Int64 }
public struct OpenLabel { public var text: String; public var n: Int64 }
@frozen public enum FrozenShape { case circle(Double), none }
public enum OpenShape { case circle(Double), none }
public struct UnownedHolder { public unowned let owner: Box; public var x: Double }
public struct BridgedUnownedHolder { public unowned let owner: BridgedBox; public var x: Double }
@frozen public struct Wide { public var a: Int64, b: Int64, c: Int64, d: Int64, e: Int64 }
@frozen public struct Pair<T> { public var a: T; public var b: T }
public protocol Shape {}
public protocol OwnedShape: AnyObject {}
public final class ShapeReference: Shape, OwnedShape { public init() {} }
public struct Square: Shape { public var sides: Int64 = 4; public init() {} }
public struct OpaqueBox { public var shape: some Shape = Square(); public var n: Double = 1 }
public struct OwnedBox { public var shape: some OwnedShape = ShapeReference(); public var n: Double = 1 }

@inline(never) public func takeOpaqueBox(_ box: OpaqueBox) {}
@inline(never) public func takeOwnedBox(_ box: OwnedBox) {}

@inline(never) public func applyFrozen(_ f: (FrozenPoint) -> Double) -> Double {
    f(FrozenPoint(x: 1, y: 2))
}
@inline(never) public func applyOpen(_ f: (OpenPoint) -> Double) -> Double {
    f(OpenPoint(x: 1, y: 2))
}
@inline(never) public func applyWide(_ f: (Wide) -> Double) -> Double {
    f(Wide(a: 1, b: 2, c: 3, d: 4, e: 5))
}
@inline(never) public func applyDoublePair(_ f: (Pair<Double>) -> Double) -> Double {
    f(Pair(a: 1, b: 2))
}
@inline(never) public func applyBytePair(_ f: (Pair<Int8>) -> Double) -> Double {
    f(Pair(a: 1, b: 2))
}
@inline(never) public func returnWidePair(_ f: () -> (Wide, Int64)) -> Int64 { f().1 }
@inline(never) public func returnOpenPair(_ f: () -> (OpenPoint, Int64)) -> Int64 { f().1 }
@inline(never) public func returnOpenLabelPair(_ f: () -> (OpenLabel, Int64)) -> Int64 { f().1 }
"""

ADDRESSABLE = 0x02000000
NON_BITWISE_TAKABLE = 0x00100000
TARGETS = [
    ("arm64-apple-macos15.4", "macosx"),
    ("arm64e-apple-ios18.4", "iphoneos"),
    ("arm64_32-apple-watchos11.4", "watchos"),
]


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def mangled(name):
    return f"$s13InferredProbe{len(name)}{name}"


def witness_flags(ir, target, name, kind):
    """The flags of the type's value witnesses, which may be a shared table."""
    # arm64e metadata references the table through a signed-pointer global.
    metadata = re.search(r'^@"' + re.escape(mangled(name) + kind) + r'Mf" = [^\n]*?ptr @"([^"]+?)(?:\.ptrauth)?"',
                         ir, re.M)
    if metadata is None:
        raise RuntimeError(f"{target}: missing metadata for {name}")
    table = re.search(r'^@"' + re.escape(metadata[1]) + r'" = [^\n]*%swift\.(?:enum_)?vwtable '
                      r'\{[^\n]*?, i(?:32|64) \d+, i(?:32|64) \d+, i32 (\d+), i32 \d+', ir, re.M)
    # The runtime's known tables, such as $sBi128_WV, describe plain bytes.
    if table is None and metadata[1].startswith("$sB"):
        return 0
    if table is None:
        raise RuntimeError(f"{target}: missing value witnesses {metadata[1]} for {name}")
    return int(table[1])


def property_header(ir, target, name):
    """The key-path component header that starts a property descriptor.
    Identical trivial descriptors are aliases of one zero-initialized one."""
    definition = re.search(r'^@"' + re.escape(name) + r'" = ([^\n]*)', ir, re.M)
    if definition is None:
        raise RuntimeError(f"{target}: missing property descriptor {name}")
    alias = re.match(r'alias [^,]*, ptr @"([^"]+)"', definition[1])
    if alias:
        return property_header(ir, target, alias[1])
    if "zeroinitializer" in definition[1]:
        return 0
    header = re.search(r'<\{ i32 (\d+)', definition[1])
    if header is None:
        raise RuntimeError(f"{target}: re-evaluate property descriptor {name}")
    return int(header[1])


def parameter_types(ir, target, function):
    """The IR types of a function's parameters, such as ["ptr", "double"]."""
    start = re.search(r'^define swiftcc [^\n]*@"[^"]*' + function + r'[^"]*"\(', ir, re.M)
    if start is None:
        raise RuntimeError(f"{target}: missing {function}")
    depth, end = 1, start.end()
    while depth:
        depth += {"(": 1, ")": -1}.get(ir[end], 0)
        end += 1
    parameters = ir[start.end():end - 1]
    return [parameter.split()[0] for parameter in parameters.split(", ") if parameter]


def discriminator(ir, target, function):
    body = re.search(r'^define swiftcc[^\n]*' + function + r'[^\n]*\{.*?^}', ir, re.M | re.S)
    if body is None:
        raise RuntimeError(f"{target}: missing {function}")
    found = re.findall(r'"ptrauth"\(i32 0, i64 (\d+)\)', body[0])
    if len(found) != 1:
        raise RuntimeError(f"{target}: re-evaluate the closure call in {function}: {found}")
    return int(found[0])


def check(ir, target, evolution):
    def require(condition, fact):
        if not condition:
            raise RuntimeError(f"{target} ({'evolution' if evolution else 'fixed'}): {fact}")

    flags = {name: witness_flags(ir, target, name, kind) for name, kind in [
        ("FrozenPoint", "V"), ("OpenPoint", "V"), ("FrozenLabel", "V"), ("OpenLabel", "V"),
        ("FrozenShape", "O"), ("OpenShape", "O"), ("OpaqueBox", "V"), ("OwnedBox", "V"),
        ("UnownedHolder", "V"), ("BridgedUnownedHolder", "V"),
    ]}
    addressable = {name: bool(value & ADDRESSABLE) for name, value in flags.items()}
    require(not addressable["FrozenPoint"] and not addressable["FrozenShape"],
            "frozen values without String fields must leave the addressable bit clear")
    require(addressable["OpenPoint"] == evolution and addressable["OpenShape"] == evolution,
            "resilient values, and only those, must set the addressable bit")
    require(addressable["FrozenLabel"] and addressable["OpenLabel"],
            "a String field must set the addressable bit")
    require(addressable["OpaqueBox"] and addressable["OwnedBox"] == evolution,
            "an opaque field that is not class-bound, and only that, must set the addressable bit")
    takable = {name: not flags[name] & NON_BITWISE_TAKABLE for name in ["UnownedHolder", "BridgedUnownedHolder"]}
    require(takable["UnownedHolder"] and not takable["BridgedUnownedHolder"],
            "an unowned reference must be bitwise-takable exactly when its referent is native")
    if not evolution:
        boxes = {name: parameter_types(ir, target, name) for name in ["takeOpaqueBox", "takeOwnedBox"]}
        require(boxes["takeOpaqueBox"] == ["ptr"],
                f"an opaque field that is not class-bound must pass its struct by address: {boxes}")
        require(boxes["takeOwnedBox"] != ["ptr"],
                f"a class-bound opaque field must leave its struct loadable: {boxes}")

    cases = {name: re.search(r'^@"' + re.escape(mangled(name)) + r'O[^"]*WC" =', ir, re.M) is not None
             for name in ["FrozenShape", "OpenShape"]}
    require(cases["OpenShape"] == evolution and not cases["FrozenShape"],
            "only resilient enums may define enum case symbols")

    stored = property_header(ir, target, mangled("OpenPoint") + "V1xSdvpMV")
    require((stored >> 24 & 0x7f) == (1 if evolution else 0) and (evolution or stored == 0),
            f"stored property descriptor header {stored:#x}")

    report = {"flags": {name: f"{value:#x}" for name, value in flags.items()},
              "enumCases": cases, "storedProperty": f"{stored:#x}"}
    if target.startswith("arm64e"):
        found = {name: discriminator(ir, target, name) for name in [
            "applyFrozen", "applyOpen", "applyWide", "applyDoublePair", "applyBytePair",
            "returnWidePair", "returnOpenPair", "returnOpenLabelPair"]}
        require(found["applyDoublePair"] == found["applyBytePair"],
                "generic arguments must not change a nominal closure parameter's hash")
        require((found["applyOpen"] == found["applyWide"]) == evolution,
                "an indirect closure parameter must hash as -indirect")
        require(found["applyFrozen"] != found["applyWide"],
                "a direct closure parameter must hash its type")
        require((found["returnOpenPair"] == found["returnOpenLabelPair"]) == evolution,
                "an address-only tuple result element must hash as -indirect")
        require(found["returnWidePair"] != found["returnOpenPair"],
                "a loadable tuple result element must hash its type at any size")
        report["discriminators"] = found
    return report


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/inferred-swift-value-codegen"
    output.mkdir(parents=True, exist_ok=True)
    source = output / "InferredProbe.swift"
    source.write_text(SOURCE)
    reports = []
    for target, sdk_name in TARGETS:
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        for evolution in [False, True]:
            ir_path = output / f"{target}-{'evolution' if evolution else 'fixed'}.ll"
            arguments = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
                         "-target", target, "-sdk", sdk, "-module-name", "InferredProbe",
                         "-emit-ir", str(source), "-o", str(ir_path)]
            if evolution:
                arguments.insert(2, "-enable-library-evolution")
            run(*arguments)
            reports.append({"target": target, "libraryEvolution": evolution,
                            **check(ir_path.read_text(), target, evolution)})
    subprocess.check_call(["python3", str(root / "scripts/generate-swift-self-addressable-types.py"),
                           "--check"])
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
