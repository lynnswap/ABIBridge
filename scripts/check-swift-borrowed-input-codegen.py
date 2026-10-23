#!/usr/bin/env python3
"""Check the compiler facts behind ABIBridge's rule for inputs that a result
can borrow from (#462).

Swift passes an input that a result has a scoped (`borrow`) dependency on by
address when its type sets the addressable-for-dependencies bit (AFD), even a
tuple, whose elements it otherwise passes separately. ABIBridge cannot tell
which inputs a result borrows from, so in a call with a scoped result it
passes a borrowed input only where Swift passes it alike with or without the
dependency, and leaves every other input undecided.

This check compiles Tests/ArchitectureValidation/CompilerProbes/BorrowedInputs
for arm64, arm64e, and arm64_32 at -Onone and -O, and fails when one of these
facts changes:

- the mangled names of functions whose results borrow from different inputs
  are equal apart from their names, while their SIL lifetime dependencies and
  conventions differ; with Swift 6.4 and later, the same holds for the
  mangled function types of closure parameters and of stored closures' field
  records;
- a borrowed input whose type sets AFD is passed by address (`@in_guaranteed`
  in SIL, one pointer in IR), a tuple as one address;
- a result cannot borrow from a consuming input, and an inout or a `copy`
  dependency leaves the convention alone.

It then decides each borrowed input as ABIBridge does, from the records
ABIBridge reads (static value-witness flags, and the kinds of values with
built-in representations), and fails when a decision differs from the
expected table, or when an input that ABIBridge passes as it would without
the dependency has another compiled convention. Each weakened variant of the
rule must disagree with some compiled signature.
"""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import subprocess

TARGETS = [
    ("arm64-apple-macos15.4", "macosx"),
    ("arm64e-apple-ios18.4", "iphoneos"),
    ("arm64_32-apple-watchos11.4", "watchos"),
]
OPTIMIZATIONS = ["-Onone", "-O"]
MODULE = "BorrowedInputs"
ADDRESSABLE = 0x2000000  # MetadataValues.h: ValueWitnessFlags::IsAddressableForDependencies

# Decisions: the input passes as it would without the dependency, it passes
# by address whatever the dependency because it is address-only or too large
# for registers, it is inout, or ABIBridge cannot decide it.
KEEPS, BY_ADDRESS, INOUT, UNDECIDED = "keeps its convention", "by address", "inout", "undecided"
CLEAR, SETS, UNKNOWN = "clear", "sets", "unknown"

# Values with built-in representations, and whether ABIBridge reads them as
# setting AFD.
LEAVES = {"String": True, "Int64": False}

# Inputs of `borrow<Case>`, which take one input that the result borrows
# from, compared with `take<Case>`, which takes it without a dependency: the
# input's type as ABIBridge reads it, and the expected decision. A type is a
# tuple of a kind and its arguments:
#   ("leaf", name), ("nominal", name), ("instance", name), ("optional", type),
#   ("tuple", [types]), ("c", name), ("generic-tuple", substituted tuple),
#   and the kinds that never set AFD: reference, function, metatype,
#   collection, pointer, and class-bound (a type parameter bound to a class).
PARAMETERS = {
    "String": (("leaf", "String"), UNDECIDED),
    "OptionalString": (("optional", ("leaf", "String")), UNDECIDED),
    "Label": (("nominal", "Label"), UNDECIDED),
    "Plain": (("nominal", "Plain"), KEEPS),
    "Wide": (("nominal", "Wide"), BY_ADDRESS),
    "Int64": (("leaf", "Int64"), KEEPS),
    "Class": (("reference",), KEEPS),
    "OptionalClass": (("optional", ("reference",)), KEEPS),
    "Existential": (("existential",), BY_ADDRESS),
    "Closure": (("function",), KEEPS),
    "Array": (("collection",), KEEPS),
    "Metatype": (("metatype",), KEEPS),
    "Pointer": (("pointer",), KEEPS),
    "CStruct": (("c", "timespec"), UNDECIDED),
    "StringTuple": (("tuple", [("leaf", "String"), ("leaf", "Int64")]), UNDECIDED),
    "IntTuple": (("tuple", [("leaf", "Int64"), ("leaf", "Int64")]), KEEPS),
    "WideTuple": (("tuple", [("leaf", "String")] + [("leaf", "Int64")] * 3), UNDECIDED),
    "PairInt64": (("instance", "Pair"), UNDECIDED),
    "PairString": (("instance", "Pair"), UNDECIDED),
    "GenericTuple": (("generic-tuple", ("tuple", [("leaf", "Int64"), ("leaf", "Int64")])), UNDECIDED),
    "ClassBound": (("class-bound",), KEEPS),
    "CopiedView": (("nominal", "View"), KEEPS),
    "InoutString": (("leaf", "String"), INOUT),
}
# Parameters that ABIBridge passes by address whatever the dependency.
ADDRESS_ONLY = {"Wide", "Existential"}
# Tuples too large for registers, whose elements ABIBridge still passes
# separately.
LARGE_TUPLES = {"WideTuple"}
INOUTS = {"InoutString"}
# A value with an explicit ABI: ABIBridge decides Label the same way when a
# lookup describes it with `valueABIs` or `receiverABI`.
EXPLICIT = {"String", "OptionalString", "Label", "StringTuple"}
# `self` of `<Type>.scoped()`, compared with `<Type>.unscoped()`.
RECEIVERS = {
    "Label": (("nominal", "Label"), UNDECIDED),
    "Plain": (("nominal", "Plain"), KEEPS),
    "String": (("leaf", "String"), UNDECIDED),
    "NC": (("reference",), KEEPS),
}
# Each input of functions whose results borrow from different inputs,
# compared position by position with `takeBoth`.
MULTIPLE = {"borrowFirst": [UNDECIDED, UNDECIDED], "borrowSecond": [UNDECIDED, UNDECIDED],
            "borrowBoth": [UNDECIDED, UNDECIDED]}
# With Swift 6.4 and later: the parameter of the closure that
# `callBorrowing<Case>` takes, compared with the one `call<Case>` takes.
CLOSURES = {"String": (("leaf", "String"), UNDECIDED), "Plain": (("nominal", "Plain"), KEEPS)}

WEAKENED = {
    "explicit": "a value with a built-in representation or an explicit ABI keeps that convention",
    "receivers": "self keeps its convention",
    "first-input": "a result borrows only from its first input",
    "tuples": "a tuple too large for registers passes by address",
    "generic-tuples": "a tuple that depends on generic parameters follows its arguments' types",
    "c-types": "an imported C struct leaves AFD clear",
    "closures": "a closure's parameters keep their conventions",
}


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


# MARK: Compiled signatures

def brackets(text):
    """Yields each index of `text` with the bracket depth after it, outside
    quotes; the `>` of a function arrow (`->`) closes nothing."""
    depth, quoted = 0, False
    for index, character in enumerate(text):
        if character == '"':
            quoted = not quoted
        elif not quoted and character in "({[<":
            depth += 1
        elif not quoted and character in ")}]>" and not (character == ">" and text[index - 1:index] == "-"):
            depth -= 1
        yield index, character, depth, quoted


def group_end(text, start):
    """The index after the bracketed group that opens at `start`."""
    for index, _, depth, _ in brackets(text[start:]):
        if depth == 0:
            return start + index + 1
    raise RuntimeError(f"unbalanced text: {text[start:start + 80]}")


def elements(text):
    """The top-level elements of a parameter list's text."""
    parts, start = [], 0
    for index, character, depth, quoted in brackets(text):
        if not quoted and character == "," and depth == 0:
            parts.append(text[start:index].strip())
            start = index + 1
    return [part for part in parts + [text[start:].strip()] if part]


class Compiled:
    """The IR and SIL signatures of the fixture's functions, by symbol, and
    their demangled names."""

    def __init__(self, ir, sil):
        self.ir = {}
        for found in re.finditer(r'^define [^@\n]*@"(\$s[^"]+)"\(', ir, re.M):
            parameters = elements(ir[found.end():group_end(ir, found.end() - 1) - 1])
            # Only the type and whether a pointer addresses a value or is
            # self matter; other attributes follow optimization.
            self.ir[found[1]] = [" ".join([parameter.split()[0]] + [flag for flag in ("noalias", "swiftself")
                                                                  if flag in parameter.split()])
                                 for parameter in parameters]
        self.sil = dict(re.findall(r"^sil (?:\[[\w_]+\] )*@(\$s\S+) : \$(.*) \{$", sil, re.M))
        self.fields = {}
        for name, mangled in re.findall(r'^@"\$s\d+' + MODULE + r'\d+(\w+?)VMF" = .*?ptrtoint \(ptr @"symbolic [^"]*'
                                        r'" .*?ptrtoint \(ptr @"symbolic ([^"]+)"', ir, re.M):
            self.fields[name] = mangled
        symbols = sorted(set(self.ir) | set(self.sil))
        names = run("xcrun", "swift-demangle", "--compact", *symbols).splitlines()
        self.names = dict(zip(symbols, names))
        # Static value-witness flags of the fixture's nongeneric types, by
        # name. The runtime's tables for builtin storage describe plain bytes.
        tables = {table: int(flags) for table, flags
                  in re.findall(r'^@"(\$s\w+WV)" = .*, i32 (\d+), i32 \d+ \}', ir, re.M)}
        self.flags = {}
        for name, table in re.findall(r'^@"\$s\d+' + MODULE + r'\d+(\w+?)VMf" = .*?@"?(\$s\w+WV)\b', ir, re.M):
            self.flags[name] = 0 if table.startswith("$sB") else tables[table]

    def symbol(self, name):
        """The symbol whose demangling starts with `name` and its generic
        parameters or parameters."""
        found = [symbol for symbol, demangled in self.names.items()
                 if demangled.startswith((name + "(", name + "<"))]
        if len(found) != 1:
            raise RuntimeError(f"re-evaluate the fixture function {name}: {found}")
        return found[0]


def sil_parameters(function_type):
    """The parameters of a SIL function type, after its convention and
    generic signature, as (convention, type)."""
    text = re.sub(r"^(@[\w_]+(\([^)]*\))? )*", "", function_type)
    if text.startswith("<"):
        text = text[group_end(text, 0):].lstrip()
    found = []
    for parameter in elements(text[1:group_end(text, 0) - 1]):
        attributes = re.match(r"((?:@[\w_]+ )*)(.*)", parameter)
        found.append((attributes[1].strip(), attributes[2]))
    return found


def is_address(convention):
    return any(word in convention.split() for word in ("@in_guaranteed", "@in", "@inout"))


def closure_parameters(function_type):
    """The parameters of the closure that is a SIL function type's first
    parameter."""
    convention, closure = sil_parameters(function_type)[0]
    return sil_parameters(closure)


# MARK: ABIBridge's rule

class Rules:
    def __init__(self, compiled, weakened=None):
        self.compiled, self.weakened = compiled, weakened
        # Only static value witnesses from a module that sets AFD for some
        # type show a clear bit.
        self.module_sets = any(flags & ADDRESSABLE for flags in compiled.flags.values())

    def weak(self, name):
        return self.weakened == name

    def addressability(self, model):
        kind = model[0]
        if kind == "leaf":
            return SETS if LEAVES[model[1]] else CLEAR
        if kind in ("reference", "function", "metatype", "collection", "pointer", "existential", "class-bound"):
            return CLEAR
        if kind == "optional":
            return self.addressability(model[1])
        if kind == "tuple":
            found = [self.addressability(element) for element in model[1]]
            return SETS if SETS in found else UNKNOWN if UNKNOWN in found else CLEAR
        if kind == "c":
            return CLEAR if self.weak("c-types") else SETS
        if kind == "instance":
            return UNKNOWN
        if kind == "generic-tuple":
            return self.addressability(model[1]) if self.weak("generic-tuples") else UNKNOWN
        if kind == "nominal":
            if not self.module_sets or model[1] not in self.compiled.flags:
                return UNKNOWN
            return SETS if self.compiled.flags[model[1]] & ADDRESSABLE else CLEAR
        raise RuntimeError(f"no rule for {kind}")

    def decide(self, name, model, receiver=False, position=0, closure=False):
        if name in INOUTS:
            return INOUT
        if name in ADDRESS_ONLY or (self.weak("tuples") and name in LARGE_TUPLES):
            return BY_ADDRESS
        if (self.weak("explicit") and name in EXPLICIT) or (self.weak("receivers") and receiver) \
                or (self.weak("first-input") and position > 0) or (self.weak("closures") and closure):
            return KEEPS
        return KEEPS if self.addressability(model) == CLEAR else UNDECIDED


# MARK: Checks

def compile_configuration(root, output, target, sdk_name, optimization):
    fixtures = root / "Tests/ArchitectureValidation/CompilerProbes/BorrowedInputs"
    directory = output / f"{target}{optimization}"
    directory.mkdir(parents=True, exist_ok=True)
    sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
    command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", optimization, "-target", target,
               "-sdk", sdk, "-enable-experimental-feature", "Lifetimes", "-module-name", MODULE,
               str(fixtures / "Provider.swift")]
    run(*command, "-emit-ir", "-o", str(directory / "provider.ll"))
    run(*command, "-emit-sil", "-o", str(directory / "provider.sil"))
    return directory


def check_rejected(root, require):
    """A result cannot borrow from a consuming parameter, from an
    initializer's parameter, which is consuming by default, or from a
    consuming self."""
    source = root / "Tests/ArchitectureValidation/CompilerProbes/BorrowedInputs/Rejected.swift"
    result = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-typecheck",
                             "-enable-experimental-feature", "Lifetimes", "-diagnostic-style", "llvm", str(source)],
                            capture_output=True, text=True)
    lines = source.read_text().splitlines()

    def line(text):
        return next(index for index, content in enumerate(lines, 1) if text in content)
    message = "invalid use of borrow dependence with consuming ownership"
    expected = {(line("public init(_ s: String)"), message), (line("func borrowConsuming"), message),
                (line("consuming func scoped"), message)}
    found = {(int(number), text) for number, text
             in re.findall(r"Rejected\.swift:(\d+):\d+: error: (.+)$", result.stderr, re.M)}
    require(result.returncode != 0 and found == expected,
            f"a borrow dependency on a consuming input must not type-check: {sorted(found)}")


def unnamed(demangled, name):
    """A demangled function without its name."""
    return demangled.replace(f"{MODULE}.{name}(", f"{MODULE}.(", 1)


def check_records(compiled, closures, label, require):
    """No record shows which input a result borrows from."""
    functions = {name: compiled.symbol(f"{MODULE}.{name}") for name in MULTIPLE}
    signatures = {unnamed(compiled.names[symbol], name) for name, symbol in functions.items()}
    dependencies = {re.search(r"@lifetime\(([^)]*)\)", compiled.sil[functions[name]])[1] for name in MULTIPLE}
    require(len(signatures) == 1 and len(dependencies) == len(MULTIPLE),
            f"{label}: functions whose results borrow from different inputs must have equal mangled types "
            f"and different SIL dependencies: {sorted(signatures)}, {sorted(dependencies)}")
    if not closures:
        return
    borrowing, plain = (compiled.symbol(f"{MODULE}.{name}") for name in ("callBorrowingString", "callString"))
    require(unnamed(compiled.names[borrowing], "callBorrowingString") == unnamed(compiled.names[plain], "callString")
            and closure_parameters(compiled.sil[borrowing]) != closure_parameters(compiled.sil[plain]),
            f"{label}: closure parameter types must mangle alike whatever their lifetime dependencies")
    require(compiled.fields.get("HoldsBorrowing") is not None
            and compiled.fields.get("HoldsBorrowing") == compiled.fields.get("HoldsString"),
            f"{label}: the field records of stored closures must hold equal types whatever their lifetime "
            f"dependencies: {compiled.fields}")


def positions(compiled, closures):
    """(kind, name, model, expected, position, compiled alike) for each
    borrowed input, where `compiled alike` says whether Swift passes it as it
    does without the dependency."""
    found = []
    for name, (model, expected) in PARAMETERS.items():
        borrowed, plain = (compiled.symbol(f"{MODULE}.{prefix}{name}") for prefix in ("borrow", "take"))
        found.append(("parameter", name, model, expected, 0, compiled.ir[borrowed] == compiled.ir[plain]))
    for name, (model, expected) in RECEIVERS.items():
        owner = "Swift.String" if name == "String" else f"{MODULE}.{name}"
        prefix = f"(extension in {MODULE}):{owner}" if name == "String" else owner
        borrowed, plain = (compiled.symbol(f"{prefix}.{method}") for method in ("scoped", "unscoped"))
        found.append(("self", name, model, expected, 0, compiled.ir[borrowed] == compiled.ir[plain]))
    plain = sil_parameters(compiled.sil[compiled.symbol(f"{MODULE}.takeBoth")])
    for name, expected in MULTIPLE.items():
        borrowed = sil_parameters(compiled.sil[compiled.symbol(f"{MODULE}.{name}")])
        for position, decision in enumerate(expected):
            found.append(("parameter", name, ("leaf", "String"), decision, position,
                          borrowed[position] == plain[position]))
    if closures:
        for name, (model, expected) in CLOSURES.items():
            borrowed, plain = (closure_parameters(compiled.sil[compiled.symbol(f"{MODULE}.{prefix}{name}")])
                               for prefix in ("callBorrowing", "call"))
            found.append(("closure parameter", name, model, expected, 0, borrowed == plain))
    return found


def check_facts(compiled, label, require):
    """A borrowed input whose type sets AFD is passed by address, in IR as
    one pointer; a `copy` or inout dependency changes nothing."""
    for name in ["String", "OptionalString", "Label", "CStruct", "StringTuple", "WideTuple", "PairString",
                 "GenericTuple"]:
        symbol = compiled.symbol(f"{MODULE}.borrow{name}")
        parameters = sil_parameters(compiled.sil[symbol])
        require(len(parameters) == 1 and "@in_guaranteed" in parameters[0][0].split()
                and compiled.ir[symbol][0] == "ptr noalias",
                f"{label}: borrow{name} must take its input as one address: {compiled.sil[symbol]}")
    for name in ["CopiedView", "InoutString"]:
        symbol = compiled.symbol(f"{MODULE}.borrow{name}")
        require(compiled.ir[symbol] == compiled.ir[compiled.symbol(f"{MODULE}.take{name}")],
                f"{label}: borrow{name} must keep the convention of its input")


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/swift-borrowed-input-codegen"
    version = re.search(r"Swift version (\d+)\.(\d+)", run("xcrun", "swiftc", "--version"))
    # Swift 6.4 accepts lifetime dependencies in function types.
    closures = (int(version[1]), int(version[2])) >= (6, 4)
    configurations = [(target, sdk, optimization) for target, sdk in TARGETS for optimization in OPTIMIZATIONS]
    with ThreadPoolExecutor(max_workers=len(configurations)) as pool:
        directories = list(pool.map(lambda arguments: compile_configuration(root, output, *arguments),
                                    configurations))
    problems = []

    def require(condition, message):
        if not condition:
            problems.append(message)
    check_rejected(root, require)

    decisions, disagreements = {}, {name: 0 for name in WEAKENED}
    for (target, _, optimization), directory in zip(configurations, directories):
        label = f"{target} {optimization}"
        compiled = Compiled((directory / "provider.ll").read_text(), (directory / "provider.sil").read_text())
        check_records(compiled, closures, label, require)
        check_facts(compiled, label, require)
        rules = Rules(compiled)
        found = positions(compiled, closures)
        for kind, name, model, expected, position, alike in found:
            arguments = dict(receiver=kind == "self", position=position, closure=kind == "closure parameter")
            decision = rules.decide(name, model, **arguments)
            case = f"{kind} {position} of {name}" if kind == "parameter" and name in MULTIPLE else f"{kind} {name}"
            decisions.setdefault(case, set()).add(f"{decision}, compiled {'alike' if alike else 'differently'}")
            require(decision == expected, f"{label}: {case} is {decision}, expected {expected}")
            require(decision == UNDECIDED or alike,
                    f"{label}: {case} {decision}, but Swift passes it differently where the result borrows from it")
            for weakened in WEAKENED:
                disagreements[weakened] += Rules(compiled, weakened).decide(name, model, **arguments) != UNDECIDED \
                    and not alike
    for name, description in WEAKENED.items():
        if name == "closures" and not closures:
            continue
        require(disagreements[name], f"no compiled signature disagrees with the weakened rule '{description}', "
                                     "so the fixtures no longer exercise its guard")

    report = {"compiler": run("xcrun", "swiftc", "--version").strip(), "runtimeTested": False,
              "closureLifetimes": closures,
              "decisions": {case: sorted(found) for case, found in decisions.items()},
              "weakenedDisagreements": disagreements}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if problems:
        raise RuntimeError("\n".join(problems))


if __name__ == "__main__":
    main()
