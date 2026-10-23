#!/usr/bin/env python3
"""Record concrete and reabstracted Swift closure conventions without executing them.

On arm64e it also checks that a metatype, class reference, or existential
keeps its formal type in a discriminator however many words it takes, while
an Optional of one larger than four registers hashes as passed by address,
and the compiler facts that closure discriminators of types declared in
extensions rely on (#435):

- a closure's discriminator hashes each type's declaration as the type's
  nominal type descriptor symbol spells it, including the generic signature
  of an extension of a generic type, which runtime type names omit;
- an extension of a nongeneric type is not a generic context, and an
  unconstrained extension in the module of the type it extends has no context
  descriptor of its own, so runtime names spell declarations in either;
- an extension's requirement records omit conformances to marker protocols,
  so an extension that adds only marker protocols records no requirement.
"""

import json
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def function(text, prefix, name):
    matches = re.finditer(r"^" + prefix + r"[^\n]*" + re.escape(name) + r"[^\n]*\{.*?^}", text, re.M | re.S)
    for match in matches:
        # @_cdecl emits a C thunk and a Swift body with related mangled names.
        if prefix == "sil" and "@convention(thin)" not in match[0].splitlines()[0]:
            continue
        return match[0]
    raise RuntimeError(f"Missing compiler function: {name}")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


EXTENSION_TYPES = {
    "Helper": "Int.Helper", "Open": "Box<Int>.Open", "Inner": "Box<Int>.Inner",
    "Hidden": "Box<Int>.Hidden", "Same": "Box<Int>.Same", "Narrow": "Bounded<Int>.Narrow",
    "Constrained": "[Int].Constrained", "Marked": "Box<Int>.Marked", "Mixed": "Box<Int>.Mixed",
}
EXTENSION_SOURCE = """
public struct Box<T> {}
public protocol Base {}
public protocol Refined: Base {}
extension Int: Refined {}
public struct Bounded<T: Base> {}
extension Int { struct Helper { var x: Double } }
extension Box { struct Open { var x: Double } }
extension Box where T: Equatable {
    public struct Inner { public var x: Double }
    struct Hidden { var x: Double }
}
extension Box where T == Int { struct Same { var x: Double } }
extension Bounded where T: Refined { struct Narrow { var x: Double } }
extension Array where Element: Equatable { struct Constrained { var x: Double } }
extension Box where T: Sendable { struct Marked { var x: Double } }
extension Box where T: Equatable & Sendable { struct Mixed { var x: Double } }
""" + "".join(f"@inline(never) func apply{name}(_ f: ({spelling}) -> Double) -> Double {{ f(.init(x: 1)) }}\n"
              for name, spelling in EXTENSION_TYPES.items())


def pointer_auth_discriminator(text):
    """LLVM's stable SipHash-2-4 of `text`, in the nonzero 16-bit range."""
    mask = (1 << 64) - 1

    def rotate(value, amount):
        return ((value << amount) | (value >> (64 - amount))) & mask

    key0, key1 = 0x794a1079ebc9d4b5, 0xd48187421b8bec6f
    v = [0x736f6d6570736575 ^ key0, 0x646f72616e646f6d ^ key1,
         0x6c7967656e657261 ^ key0, 0x7465646279746573 ^ key1]

    def rounds(count):
        a, b, c, d = v
        for _ in range(count):
            a = (a + b) & mask; b = rotate(b, 13) ^ a; a = rotate(a, 32)
            c = (c + d) & mask; d = rotate(d, 16) ^ c
            a = (a + d) & mask; d = rotate(d, 21) ^ a
            c = (c + b) & mask; b = rotate(b, 17) ^ c; c = rotate(c, 32)
        v[:] = [a, b, c, d]

    data = text.encode()
    full = len(data) // 8 * 8
    words = [int.from_bytes(data[index:index + 8], "little") for index in range(0, full, 8)]
    words.append(((len(data) & 0xff) << 56) | int.from_bytes(data[full:], "little"))
    for word in words:
        v[3] ^= word; rounds(2); v[0] ^= word
    v[2] ^= 0xff; rounds(4)
    return (v[0] ^ v[1] ^ v[2] ^ v[3]) % 0xffff + 1


# A metatype, class reference, or existential is one value however many words
# it takes, and keeps its formal type in a discriminator. An Optional of an
# existential metatype or class existential is an enum, which Swift passes by
# address once its witness tables make it larger than four registers.
EXISTENTIAL_CLOSURES = {
    "optionalMeta3": ("f(nil)", "(M3?) -> Int", "function:1:Optional<-metatype>:1:$sSi:"),
    "optionalMeta4": ("f(nil)", "(M4?) -> Int", "function:1:-indirect:1:$sSi:"),
    "optionalMeta5": ("f(nil)", "(M5?) -> Int", "function:1:-indirect:1:$sSi:"),
    "meta5": ("f(m)", "(M5) -> Int", "function:1:-metatype:1:$sSi:"),
    "optionalMetaResult4": ("f() == nil ? 0 : 1", "() -> M4?", "function:0:1:-indirect:"),
    "metaResult5": ("_ = f(); return 0", "() -> M5", "function:0:1:-metatype:"),
    "optionalMetaElement4": ("f((nil, 0))", "((M4?, Int)) -> Int", "function:2:-indirect:$sSi:1:$sSi:"),
    "optionalMetaResultElement4": ("f().1", "() -> (M4?, Int)", "function:0:2:Optional<-metatype>:$sSi:"),
    "optionalObject4": ("f(nil)", "(C4?) -> Int", "function:1:-indirect:1:$sSi:"),
    "object5": ("f(c)", "(C5) -> Int", "function:1:-class:1:$sSi:"),
    "optionalTuple5": ("f(nil)", "((Int, Int, Int, Int, Int)?) -> Int", "function:1:-indirect:1:$sSi:"),
}
EXISTENTIAL_SOURCE = """
public protocol P1 {}
public protocol P2 {}
public protocol P3 {}
public protocol P4 {}
public protocol P5 {}
public protocol Object: AnyObject {}
public typealias M3 = any (P1 & P2 & P3).Type
public typealias M4 = any (P1 & P2 & P3 & P4).Type
public typealias M5 = any (P1 & P2 & P3 & P4 & P5).Type
public typealias C4 = any Object & P1 & P2 & P3
public typealias C5 = any Object & P1 & P2 & P3 & P4
""" + "".join(f"@inline(never) public func apply_{name}(_ f: {spelling}, _ m: M5, _ c: C5) -> Int {{ {body} }}\n"
              for name, (body, spelling, _) in EXISTENTIAL_CLOSURES.items())


def check_existential_discriminators(directory, sdk):
    source = directory / "Existentials.swift"
    source.write_text(EXISTENTIAL_SOURCE)
    ir_path = directory / "existentials.ll"
    run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
        "-target", "arm64e-apple-ios18.4", "-sdk", sdk, "-module-name", "ExistentialProbe",
        "-emit-ir", str(source), "-o", str(ir_path))
    ir = ir_path.read_text()
    discriminators = {}
    for name, (_, spelling, description) in EXISTENTIAL_CLOSURES.items():
        calls = re.findall(r'"ptrauth"\(i32 0, i64 (\d+)\)', function(ir, "define", f"apply_{name}"))
        require(len(calls) == 1, f"arm64e: re-evaluate the closure call in apply_{name}: {calls}")
        hashed = pointer_auth_discriminator(description)
        require(int(calls[0]) == hashed,
                f"arm64e: the discriminator of {spelling} is {calls[0]}, not {hashed} for {description}")
        discriminators[spelling] = hashed
    return discriminators


def check_extension_discriminators(directory, sdk):
    source = directory / "Extensions.swift"
    source.write_text(EXTENSION_SOURCE)
    ir_path = directory / "extensions.ll"
    run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone",
        "-target", "arm64e-apple-ios18.4", "-sdk", sdk, "-module-name", "ExtensionProbe",
        "-emit-ir", str(source), "-o", str(ir_path))
    ir = ir_path.read_text()
    declarations = {}
    for name in EXTENSION_TYPES:
        found = re.findall(r'^@"\$s(\w+' + str(len(name)) + name + r'V)Mn" =', ir, re.M)
        require(len(found) == 1, f"arm64e: missing the nominal type descriptor of {name}: {found}")
        declarations[name] = found[0]
        calls = re.findall(r'"ptrauth"\(i32 0, i64 (\d+)\)', function(ir, "define", f"apply{name}"))
        require(len(calls) == 1, f"arm64e: re-evaluate the closure call in apply{name}: {calls}")
        hashed = pointer_auth_discriminator(f"function:1:$s{declarations[name]}:1:$sSd:")
        require(int(calls[0]) == hashed,
                f"arm64e: the closure discriminator over {name} no longer hashes its declaration "
                f"{declarations[name]}: {calls[0]} != {hashed}")
    require(declarations["Open"] == "14ExtensionProbe3BoxV4OpenV",
            "arm64e: an unconstrained extension in its type's module must not add a context")
    helper = re.search(r'^@"\$sSi14ExtensionProbeEMXE" = [^\n]*?<\{ i32 (\d+),', ir, re.M)
    require(helper is not None and not int(helper[1]) & 0x80,
            "arm64e: an extension of a nongeneric type must not be a generic context")
    requirements = {}
    for name in ["Inner", "Marked", "Mixed"]:
        extension = declarations[name][:-len(str(len(name)) + name + "V")]
        header = re.search(r'^@"\$s' + re.escape(extension) + r'MXE" = [^\n]*?i16 (\d+), i16 (\d+),', ir, re.M)
        require(header is not None, f"arm64e: missing the extension descriptor of {name}")
        requirements[name] = int(header[2])
    require(requirements == {"Inner": 1, "Marked": 0, "Mixed": 1},
            f"arm64e: requirement records must omit marker protocols: {requirements}")
    return {"declarations": declarations, "extensionRequirements": requirements}


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-closure-codegen"
    fixtures = sorted(str(path) for path in (root / "Tests/ManagedSwiftFixtures").glob("*.swift"))
    reports = []
    for target, sdk_name in [
        ("arm64-apple-macos15.4", "macosx"),
        ("arm64e-apple-ios18.4", "iphoneos"),
        ("arm64_32-apple-watchos11.4", "watchos"),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                  "-Onone", "-target", target, "-sdk", sdk]
        run(*common, "-enable-library-evolution", "-enable-experimental-feature", "Lifetimes",
            "-module-name", "ManagedSwiftFixtures", "-emit-module", *fixtures,
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        source = root / "Tests/ManagedSwiftAdapters/ClosureAdapters.swift"
        adapter = [*common, "-module-name", "ManagedSwiftAdapters", "-I", str(directory), str(source)]
        sil_path, ir_path = directory / "closures.sil", directory / "closures.ll"
        run(*adapter, "-emit-sil", "-o", str(sil_path))
        run(*adapter, "-emit-ir", "-o", str(ir_path))
        sil, ir = sil_path.read_text(), ir_path.read_text()
        forward = function(sil, "sil", "concreteThroughGeneric")
        reverse = function(sil, "sil", "integerClosureApply")
        returned = function(sil, "sil", "integerClosureReturn")
        for name, value in [("concrete to generic", forward), ("generic to concrete", reverse),
                            ("returned to generic storage", returned)]:
            require("partial_apply" in value and "function_ref thunk" in value,
                    f"{target}: missing {name} reabstraction evidence")
        generic = function(sil, "sil", "invokeGenericClosure")
        require("@in_guaranteed" in generic and "@out Result" in generic,
                f"{target}: re-evaluate generic closure argument/result lowering")
        require("@noescape" in reverse, f"{target}: nonescaping fixture lost its contract")
        require("@owned @callee_guaranteed" in returned, f"{target}: missing owned closure result")
        consumed = function(sil, "sil", "consumeEscapingClosure")
        require("@owned @callee_guaranteed" in consumed.splitlines()[0] and "strong_release" in consumed,
                f"{target}: consuming closure must receive and release an owned context")
        initialized = next(line for line in sil.splitlines()
                           if line.startswith("sil ") and "GuaranteedClosureInitializer" in line and "@noescape" in line)
        require("@guaranteed @noescape @callee_guaranteed" in initialized,
                f"{target}: nonescaping initializer closure must remain guaranteed")

        apply = next(line for line in ir.splitlines() if line.startswith("declare ") and "applyIntegerClosure" in line)
        factory = next(line for line in ir.splitlines() if line.startswith("declare ") and "makeIntegerClosure" in line)
        require("{ ptr, ptr }" in factory, f"{target}: re-evaluate concrete closure result representation")
        invocation = function(ir, "define", "invokeGenericClosure")
        calls = [line.strip() for line in invocation.splitlines() if "call swiftcc" in line and "swiftself" in line]
        require(len(calls) == 1 and "sret(" in calls[0],
                f"{target}: expected one indirect-result callback invocation with its hidden context")
        entry = {"target": target, "nativeApply": apply, "nativeFactory": factory,
                 "genericInvocation": calls[0], "reabstractionDirections": 3}
        if target.startswith("arm64e"):
            entry["extensions"] = check_extension_discriminators(directory, sdk)
            entry["existentials"] = check_existential_discriminators(directory, sdk)
        reports.append(entry)
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(),
              "runtimeTested": False, "targets": reports}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
