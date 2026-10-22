#!/usr/bin/env python3
"""Compare ABIBridge's placement of tuple results with the compiler's calls.

Tuple results with zero, one, and several indirectly returned elements, with
and without a direct part too large for registers, are called from compiled
Swift code. Each call's result addresses, and a synchronous call's result
registers, must match the slots that ABIBridge describes for the same result
type, read from Tests/NativeConsumer's SwiftResultLayoutConsumer. ABIBridge's
placement does not depend on pointer size, so the host's description serves
every target. Async entries never use the indirect-result register, so their
addresses must match the synchronous ones as ordinary arguments, in order.
"""

import json
import os
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


# Element kinds, as SwiftResultLayoutConsumer takes them: R and S are resilient
# 8- and 24-byte structs, i is Int64, and v is an empty tuple.
SWIFT_TYPES = {"R": "R", "S": "S", "i": "Int64", "v": "()"}
INDIRECT_SIZES = {"R": 8, "S": 24}
PROBES = {
    "ZeroSmall": "ii",
    "ZeroLarge": "iiiii",
    "OneOnly": "R",
    "OneAndEmpty": "Rv",
    "OneSmall": "Ri",
    "OneLarge": "Riiiii",
    "TwoOnly": "RS",
    "TwoSmall": "RiS",
    "TwoLarge": "RiSiiii",
    "ThreeLarge": "SRiiiiiR",
}
PROVIDER_PREFIX = """public struct R {
    public var a: Int64
    public init(_ a: Int64) { self.a = a }
}
public struct S {
    public var a, b, c: Int64
    public init(_ a: Int64) { (self.a, b, c) = (a, a + 1, a + 2) }
}
"""


def swift_type(elements):
    types = [SWIFT_TYPES[kind] for kind in elements]
    return types[0] if len(types) == 1 else "(" + ", ".join(types) + ")"


def swift_value(elements):
    values = {"R": "R(1)", "S": "S(2)", "i": "3", "v": "()"}
    items = [values[kind] for kind in elements]
    return items[0] if len(items) == 1 else "(" + ", ".join(items) + ")"


def sources():
    provider, caller = [PROVIDER_PREFIX], ["import TupleResultProvider\n"]
    for name, elements in PROBES.items():
        result = swift_type(elements)
        provider.append(f"@inline(never) public func probe{name}() -> {result} {{ {swift_value(elements)} }}\n")
        provider.append(f"@inline(never) public func probe{name}Async() async -> {result} {{ {swift_value(elements)} }}\n")
        caller.append(f"public func call{name}() {{ _ = probe{name}() }}\n")
        caller.append(f"public func closure{name}(_ body: () -> {result}) {{ _ = body() }}\n")
        caller.append(f"public func callAsync{name}() async {{ _ = await probe{name}Async() }}\n")
        caller.append(f"public func closureAsync{name}(_ body: () async -> {result}) async {{ _ = await body() }}\n")
    return "".join(provider), "".join(caller)


def arguments(line, start):
    """The arguments of the call whose list opens at `line[start]`."""
    parts, depth, begin = [], 0, start + 1
    for index in range(start, len(line)):
        character = line[index]
        if character in "(<{[":
            depth += 1
        elif character in ")>}]":
            depth -= 1
            if depth == 0:
                tail = line[begin:index].strip()
                return parts + [tail] if tail else parts
        elif character == "," and depth == 1:
            parts.append(line[begin:index].strip())
            begin = index + 1
    raise RuntimeError(f"Unterminated call: {line}")


def probe_call(ir, user, callee):
    """The return type and arguments of the one call in `user` to `callee`,
    or to a closure when `callee` is None."""
    identifier = f"{len(user)}{user}"
    calls = []
    for function in re.finditer(r'^define [^\n]*' + identifier + r'[^\n]*\{\n(.*?)^\}', ir, re.M | re.S):
        for line in function[1].splitlines():
            match = re.search(r'\bcall (?:swiftcc|swifttailcc) (.*?) (@"[^"]+"|@[\w.$]+|%[\w.]+)\(', line)
            if not match:
                continue
            values = arguments(line, match.end() - 1)
            if callee is None and not any("swiftself" in value for value in values):
                continue
            if callee is not None and f"{len(callee)}{callee}" not in match[2]:
                continue
            calls.append((line.strip(), match[1], values))
    require(len(calls) == 1, f"Expected one probe call in {user}: {[call[0] for call in calls]}")
    return calls[0]


def compiler_slots(call, elements, asynchronous):
    """The compiler's result slots: addresses in call order, then registers.
    IRGen names the caller's storage for a direct result passed by address
    `call.aggresult`; the other addresses are element outputs in tuple order."""
    line, returned, values = call
    indirect = [kind for kind in elements if kind in INDIRECT_SIZES]
    direct_size = 8 * elements.count("i")
    slots = []
    for value in values:
        if any(attribute in value for attribute in ["swiftself", "swiftasync", "swifterror"]):
            break
        role = "indirect-result" if "sret(" in value else "output"
        if value.split()[-1] == "%call.aggresult":
            slots.append((role, direct_size))
        else:
            require(indirect, f"Unexpected result address {value} in {line}")
            slots.append((role, INDIRECT_SIZES[indirect.pop(0)]))
    require(not indirect, f"Missing element outputs in {line}")
    if asynchronous:
        require(returned == "void", f"Async entries return through their continuation: {line}")
        return slots
    sizes = {"i64": 8, "i32": 4, "i16": 2, "i8": 1, "double": 8, "float": 4}
    scalars = re.findall(r"\b(?:i\d+|ptr|double|float)\b", returned)
    require((returned == "void") != bool(scalars) and all(scalar in sizes for scalar in scalars),
            f"Unexpected result registers in {line}")
    for scalar in scalars:
        slots.append(("float" if scalar in ["double", "float"] else "integer", sizes[scalar]))
    return slots


def abibridge_slots(description):
    """The slots in an ABICopySwiftValueLoweringDescription result."""
    slots = []
    for part in re.findall(r"(?:\(|, )([^,()]+)", description):
        address = re.fullmatch(r"(output|indirect-result) address of (\d+) bytes aligned to \d+", part)
        component = re.fullmatch(r"(\d+)-byte (integer|float) at \d+", part)
        require(address or component, f"Unexpected lowering description: {description}")
        slots.append((address[1], int(address[2])) if address else (component[2], int(component[1])))
    return slots


def placement(slots):
    """The indirect-result register is outside the ordinary argument sequence,
    so only whether it holds an address counts, not its position in a list."""
    return sorted(slots, key=lambda slot: slot[0] != "indirect-result")


def consumer_descriptions(root):
    build = Path(os.environ.get("ABI_CONSUMER_BUILD_DIR", root / ".build/native-consumer"))
    package = ["--package-path", str(root / "Tests/NativeConsumer"), "--scratch-path", str(build)]
    subprocess.run(["xcrun", "swift", "build", *package, "--product", "SwiftResultLayoutConsumer"], check=True)
    binary = Path(run("xcrun", "swift", "build", *package, "--show-bin-path").strip())
    lines = run(str(binary / "SwiftResultLayoutConsumer"), *PROBES.values()).splitlines()
    require(len(lines) == len(PROBES), f"Unexpected consumer output: {lines}")
    return dict(zip(PROBES, lines))


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-tuple-result-codegen"
    output.mkdir(parents=True, exist_ok=True)
    descriptions = consumer_descriptions(root)
    expected = {name: placement(abibridge_slots(text)) for name, text in descriptions.items()}
    provider_source, caller_source = sources()
    (output / "TupleResultProvider.swift").write_text(provider_source)
    (output / "TupleResultCaller.swift").write_text(caller_source)
    reports = []
    for target, sdk_name in [
        ("arm64-apple-macos15.4", "macosx"),
        ("arm64e-apple-ios18.4", "iphoneos"),
        ("arm64_32-apple-watchos11.4", "watchos"),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
                  "-target", target, "-sdk", sdk]
        run(*common, "-enable-library-evolution", "-module-name", "TupleResultProvider", "-emit-module",
            str(output / "TupleResultProvider.swift"),
            "-emit-module-path", str(directory / "TupleResultProvider.swiftmodule"))
        ir_path = directory / "caller.ll"
        run(*common, "-module-name", "TupleResultCaller", "-I", str(directory), "-emit-ir",
            str(output / "TupleResultCaller.swift"), "-o", str(ir_path))
        ir = ir_path.read_text()
        calls = {}
        for name, elements in PROBES.items():
            synchronous = expected[name]
            asynchronous = [("output", size) for role, size in synchronous if role in ["output", "indirect-result"]]
            for kind, user, callee, wanted in [
                ("function", f"call{name}", f"probe{name}", synchronous),
                ("closure", f"closure{name}", None, synchronous),
                ("async function", f"callAsync{name}", f"probe{name}Async", asynchronous),
                ("async closure", f"closureAsync{name}", None, asynchronous),
            ]:
                call = probe_call(ir, user, callee)
                actual = placement(compiler_slots(call, elements, kind.startswith("async")))
                require(actual == wanted,
                        f"{target}: {kind} result {swift_type(elements)} passes {actual}, "
                        f"but ABIBridge describes {descriptions[name]}")
                calls[f"{name} {kind}"] = call[0]
        reports.append({"target": target, "calls": calls})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(), "runtimeTested": False,
              "abibridge": descriptions, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
