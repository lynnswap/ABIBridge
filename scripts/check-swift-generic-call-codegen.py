#!/usr/bin/env python3
"""Verify declaration-level generic calls and resilient borrowed callbacks."""

import json
import hashlib
from pathlib import Path
import re
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def body(ir, name):
    match = re.search(r'^define [^\n]*' + name + r'[^\n]*\{.*?^}', ir, re.M | re.S)
    require(match, f"Missing compiler fixture: {name}")
    return match[0]


def main():
    root = Path(__file__).resolve().parent.parent
    vendor = root / "Sources/ABIBridgeCore/SwiftDemangling"
    upstream = json.loads((vendor / "upstream.json").read_text())
    for source in upstream["files"]:
        digest = hashlib.sha256((vendor / "Upstream" / source["path"]).read_bytes()).hexdigest()
        require(digest == source["sha256"], f"The upstream demangler snapshot changed: {source['path']}")
    output = root / ".build/swift-generic-call-codegen"
    targets = []
    for target, sdk_name in [
        ("arm64-apple-macos15.4", "macosx"),
        ("x86_64-apple-macos15.4", "macosx"),
        ("arm64e-apple-ios18.4", "iphoneos"),
        ("arm64_32-apple-watchos11.4", "watchos"),
    ]:
        directory = output / target
        directory.mkdir(parents=True, exist_ok=True)
        sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
        common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-Onone", "-target", target, "-sdk", sdk]
        provider = root / "Tests/ManagedSwiftFixtures"
        run(*common, "-enable-library-evolution", "-module-name", "ManagedSwiftFixtures", "-emit-module",
            str(provider / "RuntimeValues.swift"), str(provider / "GenericCalls.swift"),
            str(provider / "Values.swift"), str(provider / "ExplicitValues.swift"),
            "-emit-module-path", str(directory / "ManagedSwiftFixtures.swiftmodule"))
        source = root / "Tests/ManagedSwiftAdapters/GenericCallAdapters.swift"
        ir_path = directory / "calls.ll"
        sil_path = directory / "calls.sil"
        adapter = [*common, "-module-name", "InvocationEvidence", "-I", str(directory), str(source)]
        run(*adapter, "-emit-ir", "-o", str(ir_path))
        run(*adapter, "-emit-sil", "-o", str(sil_path))
        ir, sil = ir_path.read_text(), sil_path.read_text()
        generic = next(line.strip() for line in ir.splitlines() if line.startswith("declare ") and "runGeneric" in line)
        require("sret(" in generic and generic.count("ptr") == 4,
                f"{target}: generic call needs indirect result, closure pair and one metadata pointer")
        callback = next(line.strip() for line in body(ir, "probeGenericCallback").splitlines()
                        if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc void" in callback and "sret(" in callback,
                f"{target}: generic callback must initialize indirect output with its capture context")
        borrowed = next(line.strip() for line in body(ir, "probeBorrowedCallback").splitlines()
                        if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc void" in borrowed and "sret(" not in borrowed and "ptr noalias" in borrowed,
                f"{target}: resilient callback must borrow one indirect input and return Void")
        tuple_callback = next(line.strip() for line in body(ir, "probeGenericTupleCallback").splitlines()
                              if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc i16" in tuple_callback and "sret(" not in tuple_callback,
                f"{target}: a generic tuple mixes a formal output pointer with coalesced direct results")
        concrete_tuple = next(line.strip() for line in body(ir, "probeConcreteTupleCallback").splitlines()
                              if "call swiftcc" in line and "swiftself" in line)
        pack_callback = next(line.strip() for line in body(ir, "probeGenericPackCallback").splitlines()
                             if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc void" in pack_callback and "sret(" in pack_callback,
                f"{target}: a pack callback receives input and output address vectors")
        large_callback = next(line.strip() for line in body(ir, "probeLargeFixedCallback").splitlines()
                              if "call swiftcc" in line and "swiftself" in line)
        metatypes = {}
        for name in ["Thin", "Thick", "Optional", "Existential", "OptionalExistential"]:
            metatypes[name] = next(line.strip() for line in body(ir, "probe" + name + "Metatype").splitlines()
                                  if "call swiftcc" in line and "swiftself" in line)
        require("call swiftcc void" in metatypes["Thin"] and len(re.findall(r"\bptr\b", metatypes["Thin"])) == 1,
                f"{target}: singleton metatypes have no physical argument or result")
        require("call swiftcc ptr" in metatypes["Thick"] and len(re.findall(r"\bptr\b", metatypes["Thick"])) == 3,
                f"{target}: archetype metatypes preserve their metadata argument and result")
        require("call swiftcc i8" in metatypes["Optional"] and "i8 0" in metatypes["Optional"],
                f"{target}: an optional singleton metatype passes only its enum tag")
        require("call swiftcc { ptr, ptr }" in metatypes["Existential"],
                f"{target}: existential metatypes carry their metadata and witness table")
        for name in ["probeBorrowedGetter", "probeBorrowedMethod"]:
            require("swiftself" in body(ir, name), f"{target}: member needs indirect self context")
        require("@out Value" in sil and "@in_guaranteed RuntimeRecord" in sil,
                f"{target}: missing formal generic/resilient SIL conventions")
        value_ir_path = directory / "values.ll"
        run(*common, "-enable-library-evolution", "-whole-module-optimization", "-module-name", "ManagedSwiftFixtures",
            "-emit-ir", str(provider / "Generics.swift"), str(provider / "Values.swift"), "-o", str(value_ir_path))
        value_ir = value_ir_path.read_text()
        receiver = body(value_ir, "GenericValueBoxV7project").splitlines()[0]
        concrete = body(value_ir, "GenericValueBoxVAASiRszlE8concrete").splitlines()[0]
        reference = body(value_ir, "GenericValueBoxVAARlzClE9reference").splitlines()[0]
        phantom = body(value_ir, "GenericPhantomV4read").splitlines()[0]
        require("sret(" in receiver and "swiftself" in receiver and 'ptr %"GenericValueBox<Value>"' in receiver,
                f"{target}: an unbound inline field needs indirect self and its enclosing metadata")
        require("swiftself" not in concrete and "ptr" not in concrete,
                f"{target}: a same-type Int constraint removes the generic metadata and indirect self")
        require("swiftself" not in reference and "swiftcc ptr" in reference and "ptr %Value" in reference,
                f"{target}: a class-bound field has direct self but retains its generic metadata")
        require("swiftself" not in phantom and "ptr %Value" in phantom,
                f"{target}: a phantom generic parameter does not make the receiver indirect")
        object_receiver = body(value_ir, "GenericObjectValueV7project").splitlines()[0]
        superclass_receiver = body(value_ir, "GenericSuperclassValueV7project").splitlines()[0]
        nested_receiver = body(value_ir, "GenericNestedValueV7project").splitlines()[0]
        array_receiver = body(value_ir, "GenericValueBoxV5first").splitlines()[0]
        associated_object = body(value_ir, "associatedObjectGeneric").splitlines()[0]
        for entry in [object_receiver, superclass_receiver]:
            require("swiftcc ptr" in entry and "swiftself" not in entry and "ptr %Value" in entry,
                    f"{target}: nominal class constraints preserve direct self and metadata")
        require("swiftself" in nested_receiver and 'ptr %"GenericNestedValue<Value>"' in nested_receiver,
                f"{target}: an inline nested generic field preserves indirect self")
        require("sret(" in array_receiver and "swiftself" not in array_receiver
                and "ptr %Element" in array_receiver and "ptr %Value" not in array_receiver,
                f"{target}: a same-type Array expression keeps only its element metadata")
        require("swiftcc ptr" in associated_object and "sret(" not in associated_object,
                f"{target}: an associated class requirement makes the result direct")
        class_source = body(value_ir, "classSourceGeneric").splitlines()[0]
        tuple_source = body(value_ir, "tupleSourceGeneric").splitlines()[0]
        metatype_source = body(value_ir, "metatypeSourceGeneric").splitlines()[0]
        nested_source = body(value_ir, "nestedSourceGeneric").splitlines()[0]
        superclass_source = body(value_ir, "superclassSourceGeneric").splitlines()[0]
        pack_sources = {name: body(value_ir, name).splitlines()[0] for name in [
            "packClassSourceGeneric", "packMetatypeSourceGeneric", "packValueMetatypeGeneric",
            "prefixedPackSourceGeneric", "arrayPackSourceGeneric"]}
        for name in ["packClassSourceGeneric", "packMetatypeSourceGeneric"]:
            require(len(re.findall(r"\bptr\b", pack_sources[name])) == 2,
                    f"{target}: an exact pack source fulfills its shape, metadata and witnesses")
        for name in ["packValueMetatypeGeneric", "prefixedPackSourceGeneric", "arrayPackSourceGeneric"]:
            require('ptr %"each Value"' in pack_sources[name] and 'ptr %"each Value.Equatable"' in pack_sources[name],
                    f"{target}: a thin or transformed pack source preserves the generic pack requirements")
        require(len(re.findall(r"\bptr\b", pack_sources["packValueMetatypeGeneric"])) == 3,
                f"{target}: a nominal value-pack metatype is thin")
        require("ptr %Other" in class_source and "ptr %Value" not in class_source,
                f"{target}: class metadata fulfills its argument and protocol but not an unrelated parameter")
        for entry in [tuple_source, metatype_source, nested_source]:
            require("ptr %Value" not in entry and "ptr %Value.GenericSourceChild" not in entry,
                    f"{target}: explicit nominal metadata fulfills nested type arguments")
        require("ptr %Object" in superclass_source and "ptr %Value" not in superclass_source,
                f"{target}: a superclass source fulfills its arguments but not the derived archetype")
        if target.startswith("arm64e"):
            for name, entry in metatypes.items():
                discriminator = 53055 if name == "OptionalExistential" else 30738
                require(f'"ptrauth"(i32 0, i64 {discriminator})' in entry,
                        f"{name} metatype callback authentication changed")
            require('"ptrauth"(i32 0, i64 55683)' in large_callback, "Large fixed callback authentication changed")
            require('"ptrauth"(i32 0, i64 47754)' in pack_callback, "Generic pack callback authentication changed")
            require('"ptrauth"(i32 0, i64 8528)' in tuple_callback, "Generic tuple callback authentication changed")
            require('"ptrauth"(i32 0, i64 3335)' in concrete_tuple, "Concrete tuple callback authentication changed")
            require('"ptrauth"(i32 0, i64 29199)' in callback, "Generic result callback authentication changed")
            require('"ptrauth"(i32 0, i64 18589)' in borrowed, "Borrowed value callback authentication changed")
        metadata_ir_path = directory / "metadata.ll"
        run("xcrun", "clang++", "-std=c++20", "-O2", "-target", target, "-isysroot", sdk,
            "-I", str(root / "Sources/ABIBridgeCore/include"), "-S", "-emit-llvm",
            str(root / "Sources/ABIBridgeCore/SwiftGenericMetadata.cpp"), "-o", str(metadata_ir_path))
        metadata_ir = metadata_ir_path.read_text()
        run("xcrun", "clang++", "-std=c++20", "-O2", "-fvisibility=hidden", "-target", target, "-isysroot", sdk,
            "-I", str(root / "Sources/ABIBridgeCore/include"),
            "-I", str(vendor / "Support"), "-I", str(vendor / "Upstream/include"),
            "-c", str(root / "Sources/ABIBridgeCore/SwiftDemangling.cpp"), "-o", str(directory / "demangling.o"))
        if target.startswith("arm64e"):
            require(re.search(r"@llvm\.ptrauth\.auth\([^\n]*i32 3, i64 62533\)",
                              body(metadata_ir, "ABICopySwiftTypeMetadata")),
                    "The runtime TypeContextDescriptor return must use its C++ struct authentication")
        targets.append({"target": target, "genericCall": generic, "genericCallback": callback,
                        "borrowedCallback": borrowed, "tupleCallback": tuple_callback, "concreteTupleCallback": concrete_tuple,
                        "packCallback": pack_callback, "largeFixedCallback": large_callback,
                        "indirectReceiver": receiver, "concreteReceiver": concrete,
                        "referenceReceiver": reference, "phantomReceiver": phantom,
                        "objectReceiver": object_receiver, "superclassReceiver": superclass_receiver,
                        "nestedReceiver": nested_receiver, "arrayReceiver": array_receiver,
                        "associatedClass": associated_object, "classSource": class_source,
                        "tupleSource": tuple_source, "metatypeSource": metatype_source,
                        "nestedSource": nested_source, "superclassSource": superclass_source,
                        "metatypeCallbacks": metatypes, "packSources": pack_sources})
    report = {"compiler": run("xcrun", "swiftc", "--version").strip(), "runtimeTested": False,
              "demanglerRevision": upstream["revision"], "targets": targets}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
