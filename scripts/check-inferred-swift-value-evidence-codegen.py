#!/usr/bin/env python3
"""Check the compiler facts behind the inferred-value evidence of #434.

#434 decides whether a struct or enum without an explicit ABI is loadable
from records the compiler writes instead of from the addressable-for-
dependencies value-witness bit (AFD). This check compiles the fixtures in
Tests/ArchitectureValidation/CompilerProbes/InferredValueEvidence for arm64,
arm64e, and arm64_32 at -Onone and -O: a provider with and without library
evolution, and a client without it that stores and extends the types of a
library-evolution base. From the IR it reads only what the rules read: field
records, the first word of property descriptors, the symbols that spell
stored properties' declared types, nominal type descriptor flags, static
value-witness flags, enum case symbols, and class metadata flags. Only
definitions with default visibility count as symbols, as in a stripped image.

It fails when one of these facts changes:

- with library evolution, every stored `var` has a non-trivial property
  descriptor; without it, every stored property's descriptor is trivial;
- the field record of a stored `some P` holds the underlying type while the
  property's symbols spell an opaque type, and neither an enum payload nor a
  property inferred from another declaration's result can be opaque;
- a client value has static metadata exactly when the types it stores from
  another module are not resilient, but it is passed by address when one of
  them stores an opaque property at any depth; a static type that stores a
  resilient type of its own module is passed by address;
- `UsesSwiftRefcounting` is set for a native class and clear for an
  `NSObject` subclass, while both set the Swift class bit;
- a parameter or `self` that a scoped result borrows from is passed by
  address when its type sets AFD.

It then decides the value of each `take`, `make`, `borrow`, and `scoped`
function and fails when a decision differs from the expected table, or when
a loadable decision meets an indirect signature or an address-only decision
a direct one. Where a link hides enum case symbols and variable
initializers, decisions may only become undecided. Each weakened variant of
the rules, including the rules #430 removed, must disagree with some
compiled signature, so that the fixtures keep exercising every guard.
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
PROVIDER, BASE, CLIENT = "EvidenceProvider", "EvidenceBase", "EvidenceClient"

# Value-witness and class flags (MetadataValues.h); field record flags.
NON_POD, NON_BITWISE_TAKABLE, INCOMPLETE, ADDRESSABLE = 0x10000, 0x100000, 0x400000, 0x2000000
USES_SWIFT_REFCOUNTING = 0x2
IS_INDIRECT_CASE, IS_VAR = 0x1, 0x2
LOADABLE, ADDRESS_ONLY, UNDECIDED = "loadable", "address-only", "undecided"

# Decisions for a value at a `take` parameter and a `make` result, without
# and with library evolution. Foundation's records of Data are not part of
# the compiled modules, so DataBox stays undecided here.
PROVIDER_VALUES = {
    "Label": (LOADABLE, UNDECIDED), "FrozenLabel": (LOADABLE, UNDECIDED),
    "DataBox": (UNDECIDED, UNDECIDED), "Mixed": (LOADABLE, UNDECIDED),
    "Unspelled": (UNDECIDED, UNDECIDED), "Plain": (LOADABLE, ADDRESS_ONLY),
    "OpaqueLabel": (UNDECIDED, UNDECIDED), "OpaqueString": (UNDECIDED, UNDECIDED),
    "StructuralOpaque": (UNDECIDED, UNDECIDED), "HiddenOpaque": (UNDECIDED, UNDECIDED),
    "PrivateOpaque": (UNDECIDED, UNDECIDED), "OwnedOpaque": (UNDECIDED, UNDECIDED),
    "Secret": (UNDECIDED, ADDRESS_ONLY), "SelfAddressable": (LOADABLE, ADDRESS_ONLY),
    "Tagged": (LOADABLE, ADDRESS_ONLY), "FrozenTagged": (LOADABLE, UNDECIDED),
    "Shape": (LOADABLE, ADDRESS_ONLY),
    "PairDouble": (LOADABLE, UNDECIDED), "OpenPairDouble": (LOADABLE, UNDECIDED),
    "GInternalDouble": (LOADABLE, UNDECIDED), "GOpaqueDouble": (UNDECIDED, UNDECIDED),
    "HolderNC": (LOADABLE, UNDECIDED), "HolderOC": (ADDRESS_ONLY, ADDRESS_ONLY),
    "HolderAnyObject": (ADDRESS_ONLY, ADDRESS_ONLY),
    "EitherIntString": (LOADABLE, ADDRESS_ONLY), "EitherIntDouble": (LOADABLE, ADDRESS_ONLY),
}
# Decisions where `borrow<Name>(_:)` and `<Name>.scoped()` return a result
# that borrows from the value.
PROVIDER_SCOPED = {"Label": (UNDECIDED, UNDECIDED), "Plain": (LOADABLE, ADDRESS_ONLY)}
BASE_VALUES = {"FrozenLabel": UNDECIDED, "OpenLabel": UNDECIDED, "FrozenHoldsOpen": UNDECIDED,
               "FrozenOpaque": UNDECIDED, "Outer": UNDECIDED}
CLIENT_VALUES = {"HoldsFrozen": LOADABLE, "HoldsFPair": LOADABLE, "HoldsFrozenCase": LOADABLE,
                 "HoldsFrozenOpaque": UNDECIDED, "HoldsOuter": UNDECIDED, "HoldsOpen": ADDRESS_ONLY,
                 "HoldsOPair": ADDRESS_ONLY, "HoldsOpenCase": ADDRESS_ONLY, "Builder": LOADABLE}

WEAKENED = {
    "stored-lets": "#430: a trivial descriptor of a stored let shows a module without library evolution",
    "computed": "a trivial descriptor of a computed or static property shows a module without library evolution",
    "root-module": "a descriptor counts for the root module of its context, not for its extension's module",
    "field-records": "field records stand for declared types",
    "unspelled": "#430: a stored property that no symbol spells is not opaque",
    "missing-cases": "#430: an enum without visible enum case symbols is frozen",
    "instance-witnesses": "#430: a generic instance's value witnesses decide it",
    "unowned-pointer": "a T-dependent unowned field is a pointer whatever its referent",
    "swift-class-bit": "a referent with the Swift class bit uses native reference counting",
    "scoped-results": "a result that borrows from a value does not change its convention",
    "static-self": "static metadata shows that the type itself is not resilient",
    "sensitive": "non-POD value witnesses that no field explains do not matter",
    "parent-only": "a static parent decides a type of another module without evidence 2",
    "one-level": "a static parent needs evidence 2 only for the type it stores directly",
}

# Standard library values with explicit ABIs, and whether they set AFD.
LEAVES = {"Int": False, "Int64": False, "Double": False, "String": True}
# Kinds of symbols that spell a property's declared type.
ACCESSORS = {"PropertyDescriptor", "Getter", "Setter", "ModifyAccessor", "Modify2Accessor",
             "ReadAccessor", "Read2Accessor", "Initializer", "InitAccessor"}


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


# MARK: Demangling

class Node:
    """A node of `swift-demangle --tree-only`; equal trees have equal keys."""

    __slots__ = ("kind", "text", "children", "key")

    def __init__(self, kind, text, children):
        self.kind, self.text, self.children = kind, text, children
        self.key = (kind, text, tuple(child.key for child in children))

    def child(self, kind):
        return next((child for child in self.children if child.kind == kind), None)

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()


def unwrap(node):
    while node.kind == "Type":
        node = node.children[0]
    return node


class Demangler:
    def __init__(self):
        self.trees = {}

    def __call__(self, symbols):
        missing = sorted(set(symbols) - self.trees.keys())
        for start in range(0, len(missing), 500):
            output = run("xcrun", "swift-demangle", "--tree-only", *missing[start:start + 500])
            blocks = re.split(r"^Demangling for (\S+)\n", output, flags=re.M)[1:]
            for symbol, block in zip(blocks[::2], blocks[1::2]):
                self.trees[symbol] = self.parse(block)
        return {symbol: self.trees.get(symbol) for symbol in symbols}

    @staticmethod
    def parse(block):
        """The tree of one symbol: each line is a node, indented by two
        spaces per level; `<<NULL>>` when the symbol does not demangle."""
        root, stack = None, []
        for line in block.splitlines():
            found = re.match(r'( *)kind=(\w+)(?:, (?:text="([^"]*)"|index=(\d+)))?$', line)
            if found:
                entry = (found[2], found[3] if found[4] is None else found[4], [])
                del stack[len(found[1]) // 2:]
                if stack:
                    stack[-1][2].append(entry)
                else:
                    root = entry
                stack.append(entry)

        def build(entry):
            return Node(entry[0], entry[1], [build(child) for child in entry[2]])
        return build(root) if root else None


def nominal_name(node):
    node = unwrap(node)
    if node.kind == "Module":
        return node.text
    if node.kind == "Extension":
        return nominal_name(node.children[1])
    if node.kind.startswith("BoundGeneric"):
        return nominal_name(node.children[0])
    return f"{nominal_name(node.children[0])}.{node.children[1].text}"


def declaring_module(context, root=False):
    """The module of a context's innermost extension, otherwise its root
    module; with `root`, always the root module."""
    node = unwrap(context)
    while node.kind != "Module":
        if node.kind == "Extension" and not root:
            return node.children[0].text
        node = unwrap(node.children[1 if node.kind == "Extension" else 0])
    return node.text


def leaf(node):
    """The name of a standard library value with an explicit ABI."""
    if node.kind == "Structure" and declaring_module(node) == "Swift" and node.children[1].text in LEAVES:
        return node.children[1].text
    return None


def optional_payload(node):
    if node.kind == "BoundGenericEnum" and nominal_name(node) == "Swift.Optional":
        return unwrap(node.children[1].children[0])
    return None


def is_opaque(node):
    return any(child.kind.startswith("Opaque") for child in node.walk())


def substitute(node, arguments):
    """`node` with its generic parameters replaced by `arguments`."""
    if node.kind == "DependentGenericParamType":
        return arguments[int(node.children[1].text)]
    if not node.children:
        return node
    return Node(node.kind, node.text, [substitute(child, arguments) for child in node.children])


# MARK: IR

def group_end(text, start):
    """The index after the bracketed group that opens at `start`."""
    depth, quoted = 0, False
    for index in range(start, len(text)):
        character = text[index]
        if character == '"':
            quoted = not quoted
        elif not quoted and character in "({[<":
            depth += 1
        elif not quoted and character in ")}]>":
            depth -= 1
            if depth == 0:
                return index + 1
    raise RuntimeError(f"unbalanced IR: {text[start:start + 80]}")


def elements(text):
    """The top-level elements of an aggregate's or a parameter list's text."""
    parts, depth, start, quoted = [], 0, 0, False
    for index, character in enumerate(text):
        if character == '"':
            quoted = not quoted
        elif not quoted and character in "({[<":
            depth += 1
        elif not quoted and character in ")}]>":
            depth -= 1
        elif not quoted and character == "," and depth == 0:
            parts.append(text[start:index].strip())
            start = index + 1
    return [part for part in parts + [text[start:].strip()] if part]


class Nominal:
    """A struct, enum, or class that a nominal type descriptor (Mn) defines."""

    def __init__(self, mangling, node, flags):
        self.mangling, self.node = mangling, node
        self.kind = node.kind
        self.generic = bool(flags & 0x80)
        # Metadata initialization: 0 none, 1 singleton, 2 foreign.
        self.initialization = flags >> 16 & 0x3
        self.fields = []
        # Static value-witness flags, or the generic pattern's.
        self.witnesses = None
        self.class_flags = self.swift_class_bit = None

    @property
    def static(self):
        return not self.generic and self.initialization == 0

    def field(self, name):
        return next((field for field in self.fields if field["name"] == name), None)


class Image:
    """The definitions in one or more modules' IR, as one image holds them."""

    def __init__(self, paths, demangle):
        self.demangle = demangle
        self.texts = [path.read_text() for path in paths]
        # Each module's IR names its private globals, such as strings, alike.
        self.globals, self.exports, self.functions, self.strings, self.words = {}, set(), {}, [], {}
        for unit, text in enumerate(self.texts):
            for found in re.finditer(r'^@"(\$s[^"]+)" = ((.*?)\b(?:constant|global|alias)\b.*)$', text, re.M):
                linkage = set(found[3].split())
                if not linkage & {"external", "extern_weak"}:
                    self.globals[found[1]] = (found[2], unit)
                    if not linkage & {"internal", "private", "hidden"}:
                        self.exports.add(found[1])
            for found in re.finditer(r'^define ([^@\n]*)@"(\$s[^"]+)"\(', text, re.M):
                self.functions[found[2]] = elements(text[found.end():group_end(text, found.end() - 1) - 1])
                if not set(found[1].split()) & {"internal", "private", "hidden"}:
                    self.exports.add(found[2])
            self.strings.append(dict(re.findall(r'^(@[\w.]+) = private (?:unnamed_addr )?constant '
                                                r'\[\d+ x i8\] c"([^"\\]*)\\00"', text, re.M)))
        self.nominals = {}
        for symbol, tree in demangle([symbol for symbol in self.globals if symbol.endswith("Mn")]).items():
            if tree is None or tree.children[0].kind != "NominalTypeDescriptor":
                continue
            node = unwrap(tree.children[0].children[0])
            if node.kind in ("Structure", "Enum", "Class"):
                nominal = Nominal(symbol[2:-2], node, self.word(symbol))
                self.read_records(nominal)
                self.nominals[node.key] = nominal
        manglings = {field["mangled"] for nominal in self.nominals.values() for field in nominal.fields}
        types = demangle([f"$s{mangled}D" for mangled in manglings if mangled])
        for nominal in self.nominals.values():
            for field in nominal.fields:
                tree = types.get(f"$s{field['mangled']}D")
                field["type"] = unwrap(tree.children[0].children[0]) if tree else None

    def aggregate(self, symbol):
        """The elements of a global's initializer, following aliases; [] for
        zeroinitializer."""
        definition, _ = self.globals.get(symbol, (None, None))
        if definition is None:
            return None
        alias = re.match(r'(?:\w+ )*alias [^,]*, ptr @"([^"]+)"', definition)
        if alias:
            return self.aggregate(alias[1])
        start = re.search(r"\b(?:constant|global) ", definition).end()
        start = group_end(definition, start) if definition[start] in "{<[" else definition.index(" ", start)
        rest = definition[start:].lstrip()
        if rest.startswith("zeroinitializer"):
            return []
        inset = 2 if rest.startswith("<{") else 1
        return elements(rest[inset:group_end(rest, 0) - inset])

    def word(self, symbol):
        """A global's first 32-bit word, such as a descriptor's flags."""
        if symbol not in self.words:
            parts = self.aggregate(symbol)
            found = re.fullmatch(r"i32 (-?\d+)", parts[0]) if parts else None
            if parts and found is None:
                raise RuntimeError(f"re-evaluate the first word of {symbol}: {parts[0]}")
            self.words[symbol] = int(found[1]) & 0xFFFFFFFF if found else 0
        return self.words[symbol]

    def read_records(self, nominal):
        # A field descriptor (MF) has a five-word header, then a flags word,
        # a type reference, and a name reference per field.
        parts = self.aggregate(f"$s{nominal.mangling}MF") or []
        unit = self.globals[f"$s{nominal.mangling}Mn"][1]
        for index in range(5, len(parts) - 2, 3):
            symbolic = re.search(r'@"symbolic ([^"]+)"', parts[index + 1])
            mangled = None
            if symbolic:
                # `symbolic _____ySdG 4Base5FPairV`: each `_____` refers to the
                # context that follows.
                mangled, *references = symbolic[1].split(" ")
                for reference in references:
                    mangled = mangled.replace("_____", reference, 1)
            name = re.search(r"ptrtoint \(ptr (@[\w.]+) to", parts[index + 2])
            nominal.fields.append({"flags": int(parts[index].split()[1]), "mangled": mangled,
                                   "name": self.strings[unit][name[1]]})
        metadata = self.aggregate(f"$s{nominal.mangling}Mf") or []
        if nominal.kind == "Class":
            # The class flags follow the data word, whose bit 1 marks a Swift class.
            data = next((index for index, part in enumerate(metadata) if "@_DATA_" in part), None)
            if data is None:
                raise RuntimeError(f"re-evaluate the class metadata of {nominal.mangling}")
            word = metadata[data]
            signed = re.search(r"@(_DATA_\S+\.ptrauth)", word)
            if signed:
                word = re.search(rf"^@{re.escape(signed[1])} = .*$", self.texts[unit], re.M)[0]
            nominal.swift_class_bit = bool(int(re.search(r"@_DATA_\w+, i(?:32|64) (\d+)\)", word)[1]) & 2)
            nominal.class_flags = int(metadata[data + 1].split()[1])
        elif nominal.generic:
            nominal.witnesses = self.witness_flags(f"$s{nominal.mangling}WV")
        else:
            table = next((found[1] for part in metadata if (found := re.search(r'@"?(\$s\w+WV)', part))), None)
            nominal.witnesses = self.witness_flags(table) if table else None
            if nominal.witnesses is None:
                raise RuntimeError(f"re-evaluate the value witnesses of {nominal.mangling}")

    def witness_flags(self, table):
        # The runtime's tables for builtin storage describe plain bytes.
        if table.startswith("$sB"):
            return 0
        # Eight witnesses, the size, the stride, then the flags.
        parts = self.aggregate(table)
        return int(parts[10].split()[1]) if parts else None

    def nominal(self, node):
        node = unwrap(node)
        if node.kind.startswith("BoundGeneric"):
            node = unwrap(node.children[0])
        return self.nominals.get(node.key)


def property_symbol(tree):
    """(Variable, name, static) for a property descriptor or accessor."""
    if tree is None or tree.children[0].kind not in ACCESSORS:
        return None
    node, static = tree.children[0].children[0], False
    if node.kind == "Static":
        node, static = node.children[0], True
    if node.kind != "Variable":
        return None
    name = node.children[1]
    return node, name.text if name.kind == "Identifier" else name.children[-1].text, static


def declaration_context(tree):
    return next((node for node in tree.walk() if node.kind in ("Structure", "Enum", "Class", "Extension")), None)


# MARK: Rules

class Rules:
    """The rules that #434 proposes, over the symbols that an image shows.
    `weakened` names one guard of WEAKENED to drop."""

    def __init__(self, image, symbols, weakened=None):
        self.image, self.weakened = image, weakened
        self.spellings, self.cases, self.fixed, self.evolution = {}, set(), set(), set()
        for symbol, tree in image.demangle(sorted(symbols)).items():
            if tree is None:
                continue
            variable = property_symbol(tree)
            context = declaration_context(tree)
            if variable and not variable[2]:
                key = (unwrap(variable[0].children[0]).key, variable[1])
                self.spellings.setdefault(key, []).append(variable[0].child("Type"))
            if symbol.endswith(("vpMV", "vpZMV")) and variable and self.shows_fixed_layout(symbol, *variable):
                self.fixed.add(declaring_module(variable[0].children[0], root=self.weak("root-module")))
            if symbol.endswith("WC") and tree.children[0].kind == "EnumCase":
                self.cases.add(unwrap(tree.children[0].children[0].children[0]).key)
            # #430: symbols of the module's own declarations that only
            # library evolution exports.
            if context is not None and (symbol.endswith(("WC", "Tj", "Mo", "Mu")) or (
                    symbol.endswith("vpMV") and image.word(symbol) >> 24 & 0x7F in (1, 3))):
                self.evolution.add(declaring_module(context))

    def weak(self, name):
        return self.weakened == name

    def shows_fixed_layout(self, symbol, variable, name, static):
        """Evidence 1: a trivial descriptor of a stored var of a struct or class."""
        if self.image.word(symbol) != 0:
            return False
        nominal = self.image.nominal(variable.children[0])
        field = nominal.field(name) if nominal and nominal.kind != "Enum" and not static else None
        if field is None:
            return self.weak("computed")
        return bool(field["flags"] & IS_VAR) or self.weak("stored-lets")

    def decide(self, node, scoped=False):
        """The decision for a value of type `node`, and why."""
        decision, reason, nominal = self.value(unwrap(node), frozenset(), frozenset())
        if decision == LOADABLE and scoped and nominal is not None and not self.weak("scoped-results") \
                and (nominal.generic or nominal.witnesses & ADDRESSABLE):
            return UNDECIDED, "a result borrows from it, and it sets AFD or is a generic instance"
        return decision, reason

    def value(self, node, parents, direct):
        """`parents` holds the modules of the static ancestors that store the
        value, and `direct` the module of its parent if that is static."""
        if leaf(node):
            return LOADABLE, "explicit ABI", None
        if node.kind in ("Class", "BoundGenericClass"):
            return LOADABLE, "class reference", None
        if optional_payload(node):
            return self.value(optional_payload(node), parents, direct)
        if node.kind in ("Structure", "Enum", "BoundGenericStructure", "BoundGenericEnum"):
            return self.nominal_value(node, parents, direct)
        return UNDECIDED, f"no rule for {node.kind}", None

    def nominal_value(self, node, parents, direct):
        name, nominal = nominal_name(node), self.image.nominal(node)
        if nominal is None:
            return UNDECIDED, f"no records of {name} in the compiled modules", None
        arguments = [unwrap(child) for child in node.children[1].children] if nominal.generic else []
        # Only static value witnesses summarize the concrete fields. The
        # instances of a generic type with a fixed layout share its pattern's.
        witnesses = None if nominal.generic else nominal.witnesses
        if self.weak("instance-witnesses") and nominal.generic and nominal.witnesses is not None \
                and not nominal.witnesses & INCOMPLETE:
            witnesses = nominal.witnesses
        # #430's address-only rules.
        if nominal.initialization == 1:
            return ADDRESS_ONLY, f"{name} has singleton metadata initialization", nominal
        if witnesses is not None and witnesses & NON_BITWISE_TAKABLE:
            return ADDRESS_ONLY, f"{name} is not bitwise-takable", nominal
        if nominal.kind == "Enum" and nominal.node.key in self.cases:
            return ADDRESS_ONLY, f"{name} has enum case symbols", nominal
        module = declaring_module(nominal.node)
        inner = (parents | {module}, frozenset({module})) if nominal.static else (parents, frozenset())
        fields, undecided = [], None
        for field in nominal.fields:
            if field["flags"] & IS_INDIRECT_CASE:
                raise RuntimeError(f"{name}: the rules for indirect enum cases are not modeled")
            if field["type"] is None:
                continue
            field_type = substitute(field["type"], arguments)
            fields.append((field, field_type))
            decision, reason = self.field(field_type, *inner)
            if decision == ADDRESS_ONLY:
                return ADDRESS_ONLY, f"{name}.{field['name']}: {reason}", nominal
            if decision == UNDECIDED and undecided is None:
                undecided = f"{name}.{field['name']}: {reason}"
        if witnesses is not None and witnesses & ADDRESSABLE and module in self.evolution \
                and not any(self.explains(field_type) for _, field_type in fields):
            return ADDRESS_ONLY, f"no field of {name} explains its AFD", nominal
        # Resilience: evidence 1 for the module, or evidence 3 from a static
        # ancestor of another module.
        covered = any(parent != module for parent in parents)
        if not (covered or declaring_module(nominal.node, root=self.weak("root-module")) in self.fixed
                or (self.weak("static-self") and nominal.static)
                or (self.weak("missing-cases") and nominal.kind == "Enum")):
            return UNDECIDED, f"no evidence that {module} is built without library evolution", nominal
        # Evidence 2: a symbol spells every stored property's declared type,
        # which is not opaque. Under evidence 3, every struct at any depth
        # needs it.
        stored_by_parent = any(parent != module for parent in direct)
        skipped = self.weak("field-records") or covered and (
            self.weak("parent-only") or self.weak("one-level") and not stored_by_parent)
        if nominal.kind == "Structure" and not skipped:
            for field, _ in fields:
                declared = self.spellings.get((nominal.node.key, field["name"]), [])
                if not declared and not self.weak("unspelled"):
                    return UNDECIDED, f"no symbol spells the declared type of {name}.{field['name']}", nominal
                if any(is_opaque(type) for type in declared):
                    return UNDECIDED, f"{name}.{field['name']} is declared with an opaque type", nominal
        # #430: a @sensitive type is address-only, and only its non-POD value
        # witnesses show it.
        if witnesses is not None and witnesses & NON_POD and not self.weak("sensitive") \
                and not any(self.non_pod(field_type) for _, field_type in fields):
            return UNDECIDED, f"no field explains the non-POD value witnesses of {name}", nominal
        if undecided:
            return UNDECIDED, undecided, nominal
        return LOADABLE, "evidence 3 and 2" if covered else "evidence 1 and 2", nominal

    def field(self, node, parents, direct):
        if node.kind == "Weak":
            return ADDRESS_ONLY, "weak reference"
        if node.kind != "Unowned":
            return self.value(node, parents, direct)[:2]
        referent = unwrap(node.children[0])
        if self.weak("unowned-pointer"):
            return LOADABLE, "unowned reference"
        if referent.kind in ("ProtocolListWithAnyObject", "ProtocolList"):
            return ADDRESS_ONLY, "unowned existential without a native superclass"
        nominal = self.image.nominal(referent) if referent.kind == "Class" else None
        if nominal is None:
            return UNDECIDED, f"unknown reference counting of {referent.kind}"
        native = nominal.swift_class_bit if self.weak("swift-class-bit") \
            else nominal.class_flags & USES_SWIFT_REFCOUNTING
        return (LOADABLE, "native unowned reference") if native else (ADDRESS_ONLY, "non-native unowned reference")

    def explains(self, node):
        """#430: whether a field explains its parent's AFD; unknown counts."""
        if leaf(node):
            return LEAVES[leaf(node)]
        if optional_payload(node):
            return self.explains(optional_payload(node))
        if node.kind not in ("Structure", "Enum", "BoundGenericStructure", "BoundGenericEnum"):
            return False
        nominal = self.image.nominal(node)
        return nominal is None or not nominal.static or bool(nominal.witnesses & ADDRESSABLE)

    def non_pod(self, node):
        """Whether a field needs nontrivial copies; unknown does not count."""
        if node.kind in ("Weak", "Unowned", "Class", "BoundGenericClass"):
            return True
        if leaf(node):
            return leaf(node) == "String"
        if optional_payload(node):
            return self.non_pod(optional_payload(node))
        nominal = self.image.nominal(node) if node.kind.startswith(("Structure", "Enum", "BoundGeneric")) else None
        if nominal is None:
            return False
        if not nominal.generic:
            return bool(nominal.witnesses & NON_POD)
        arguments = [unwrap(child) for child in node.children[1].children]
        return any(self.non_pod(substitute(field["type"], arguments)) for field in nominal.fields if field["type"])


# MARK: Compiled signatures

def positions(image, module, name, scoped):
    """(function, value type, compiled indirectly) where a value of the case
    is a `take` parameter and a `make` result, or the parameter of `borrow`
    and `self` of `scoped`."""
    found = []
    for function, owner, position in ([(f"borrow{name}", "", "parameter"), ("scoped", name, "self")] if scoped
                                      else [(f"take{name}", "", "parameter"), (f"make{name}", "", "result")]):
        prefix = f"$s{len(module)}{module}" + (f"{len(owner)}{owner}V" if owner else "") + f"{len(function)}{function}"
        candidates = image.demangle([symbol for symbol in image.functions if symbol.startswith(prefix)])
        symbol, tree = next(((symbol, tree) for symbol, tree in candidates.items()
                             if tree is not None and [child.kind for child in tree.children] == ["Function"]),
                            (None, None))
        if symbol is None:
            raise RuntimeError(f"missing the fixture function {prefix}")
        signature = unwrap(tree.children[0].child("Type"))
        value = {"parameter": lambda: signature.child("ArgumentTuple").children[0],
                 "result": lambda: signature.child("ReturnType").children[0],
                 "self": lambda: tree.children[0].children[0]}[position]()
        parameters = image.functions[symbol]
        values = [parameter for parameter in parameters if "sret(" not in parameter]
        if position == "result":
            compiled = bool(parameters) and "sret(" in parameters[0]
        elif position == "self":
            compiled = any(re.match(r"ptr .*\bnoalias\b.*\bswiftself\b", parameter) for parameter in values)
        else:
            compiled = len(values) == 1 and re.match(r"ptr .*\bnoalias\b", values[0]) is not None
        found.append((f"{owner}.{function}" if owner else function, unwrap(value), compiled))
    return found


# MARK: Facts

def check_descriptors(image, evolution, label, require):
    """Evidence 1's premise: library evolution gives every stored var a
    non-trivial property descriptor, and its absence every stored property a
    trivial one."""
    symbols = [symbol for symbol in image.globals if symbol.endswith("vpMV")]
    for symbol, tree in image.demangle(symbols).items():
        variable = property_symbol(tree)
        nominal = image.nominal(variable[0].children[0])
        field = nominal.field(variable[1]) if nominal and nominal.kind != "Enum" else None
        if field is None:
            continue
        header = image.word(symbol)
        if evolution(declaring_module(nominal.node)):
            require(header != 0 or not field["flags"] & IS_VAR,
                    f"{label}: library evolution gives the stored var {symbol} a trivial descriptor")
        else:
            require(header == 0, f"{label}: the stored property {symbol} has the descriptor {header:#x} "
                                 "without library evolution")


def check_opaque_records(image, rules, module, cases, label, require):
    """Evidence 2's premise: a field record holds an opaque property's
    underlying type, while the property's symbols spell an opaque type."""
    for typename, field, underlying, exported in cases:
        nominal = next(n for n in image.nominals.values() if nominal_name(n.node) == f"{module}.{typename}")
        spelled = rules.spellings.get((nominal.node.key, field), [])
        require(nominal.field(field)["mangled"] == underlying,
                f"{label}: the field record of {typename}.{field} must hold {underlying}")
        require((spelled or not exported) and all(is_opaque(type) for type in spelled),
                f"{label}: the symbols of {typename}.{field} must spell an opaque type")


def check_rejected(root, require):
    """Enum payloads cannot be opaque, and a stored property cannot take
    another declaration's opaque result type, so a stored property's symbols
    spell every opaque type it stores."""
    source = root / "Tests/ArchitectureValidation/CompilerProbes/InferredValueEvidence/Rejected.swift"
    result = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-typecheck",
                             "-diagnostic-style", "llvm", str(source)], capture_output=True, text=True)
    lines = source.read_text().splitlines()

    def line(text):
        return next(index for index, content in enumerate(lines, 1) if text in content)
    payload = "'some' types are only permitted in properties, subscripts, and functions"
    expected = {(line("case a(some P)"), payload), (line("case a([some P])"), payload),
                (line("var x = makeP()"), "property definition has inferred type 'some P', involving "
                                          "the 'some' return type of another declaration")}
    found = {(int(number), message) for number, message
             in re.findall(r"Rejected\.swift:(\d+):\d+: error: (.+)$", result.stderr, re.M)}
    require(result.returncode != 0 and found == expected,
            f"opaque enum payloads and inferred opaque properties must not type-check: {sorted(found)}")


def check_provider(image, rules, evolution, label, require):
    check_descriptors(image, lambda _: evolution, label, require)
    check_opaque_records(image, rules, PROVIDER, [
        ("OpaqueLabel", "x", "Si", True), ("OpaqueString", "x", "SS", True),
        ("StructuralOpaque", "x", "SiSg", True), ("HiddenOpaque", "x", "Si", False),
        ("PrivateOpaque", "x", "Si", False), ("Kinds", "op", "Si", True)], label, require)
    classes = {name: next(n for n in image.nominals.values() if nominal_name(n.node) == f"{PROVIDER}.{name}")
               for name in ["NC", "OC", "Label"]}
    require(classes["NC"].class_flags & USES_SWIFT_REFCOUNTING and classes["NC"].swift_class_bit,
            f"{label}: a native class must set UsesSwiftRefcounting and the Swift class bit")
    require(not classes["OC"].class_flags & USES_SWIFT_REFCOUNTING and classes["OC"].swift_class_bit,
            f"{label}: an NSObject subclass must clear UsesSwiftRefcounting and set the Swift class bit")
    if not evolution:
        require(classes["Label"].witnesses & ADDRESSABLE, f"{label}: a String field must set AFD")
        compiled = [indirect for *_, indirect in positions(image, PROVIDER, "Label", True)]
        require(all(compiled), f"{label}: a value that sets AFD and that a result borrows from must be "
                               "passed by address")


def check_client(image, rules, label, require):
    """Evidence 3's premise: a client value has static metadata exactly when
    the types it stores from another module are not resilient."""
    check_descriptors(image, lambda module: module == BASE, label, require)
    check_opaque_records(image, rules, BASE, [("FrozenOpaque", "x", "Si", True)], label, require)
    for name, singleton in [("HoldsOpen", True), ("HoldsOPair", True), ("HoldsOpenCase", True),
                            ("HoldsFrozen", False), ("HoldsFPair", False), ("HoldsFrozenCase", False),
                            ("HoldsFrozenOpaque", False), ("HoldsOuter", False)]:
        nominal = next(n for n in image.nominals.values() if nominal_name(n.node) == f"{CLIENT}.{name}")
        require((nominal.initialization == 1) == singleton,
                f"{label}: {name} must {'' if singleton else 'not '}use singleton metadata initialization")
    # Static metadata does not show that a type's own fields or the opaque
    # properties of another module's types are loadable.
    for module, name in [(BASE, "FrozenHoldsOpen"), (CLIENT, "HoldsFrozenOpaque"), (CLIENT, "HoldsOuter")]:
        nominal = next(n for n in image.nominals.values() if nominal_name(n.node) == f"{module}.{name}")
        require(nominal.static and all(indirect for *_, indirect in positions(image, module, name, False)),
                f"{label}: {name} must have static metadata and be passed by address")


# MARK: Driver

def compile_configuration(root, output, target, sdk_name, optimization):
    fixtures = root / "Tests/ArchitectureValidation/CompilerProbes/InferredValueEvidence"
    directory = output / f"{target}{optimization}"
    directory.mkdir(parents=True, exist_ok=True)
    sdk = run("xcrun", "--sdk", sdk_name, "--show-sdk-path").strip()
    common = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", optimization,
              "-target", target, "-sdk", sdk]
    provider = [*common, "-enable-experimental-feature", "Lifetimes", "-enable-experimental-feature",
                "Sensitive", "-enable-experimental-feature", "AddressableTypes", "-package-name", "evidence",
                "-module-name", PROVIDER, "-emit-ir", str(fixtures / "Provider.swift")]
    run(*provider, "-o", str(directory / "provider-fixed.ll"))
    run(*provider, "-enable-library-evolution", "-o", str(directory / "provider-evolution.ll"))
    run(*common, "-enable-library-evolution", "-module-name", BASE, "-emit-module", "-emit-module-path",
        str(directory / f"{BASE}.swiftmodule"), "-emit-ir", str(fixtures / "Base.swift"),
        "-o", str(directory / "base.ll"))
    run(*common, "-I", str(directory), "-module-name", CLIENT, "-emit-ir", str(fixtures / "Client.swift"),
        "-o", str(directory / "client.ll"))
    return directory


def hidden_symbols(image):
    """What a link shows that hides enum case symbols and variable
    initializers, as `-unexported_symbol` does. Missing symbols must only
    leave values undecided."""
    return {symbol for symbol in image.exports if not symbol.endswith(("WC", "vpfi"))}


def judge(rules, value, scoped, compiled):
    """The decision, why, and whether the compiled signature contradicts it."""
    decision, reason = rules.decide(value, scoped)
    return decision, reason, decision != UNDECIDED and (decision == ADDRESS_ONLY) != compiled


def main():
    root = Path(__file__).resolve().parent.parent
    output = root / ".build/inferred-swift-value-evidence-codegen"
    configurations = [(target, sdk, optimization) for target, sdk in TARGETS for optimization in OPTIMIZATIONS]
    with ThreadPoolExecutor(max_workers=len(configurations)) as pool:
        directories = list(pool.map(lambda arguments: compile_configuration(root, output, *arguments),
                                    configurations))
    problems = []

    def require(condition, message):
        if not condition:
            problems.append(message)
    check_rejected(root, require)

    demangle = Demangler()
    decisions, disagreements = {}, {name: 0 for name in WEAKENED}
    builds = [("provider without library evolution", ["provider-fixed.ll"], False),
              ("provider with library evolution", ["provider-evolution.ll"], True),
              ("base and client", ["base.ll", "client.ll"], None)]
    for (target, _, optimization), directory in zip(configurations, directories):
        for build, files, evolution in builds:
            label = f"{target} {optimization} {build}"
            image = Image([directory / name for name in files], demangle)
            rules, hidden = Rules(image, image.exports), Rules(image, hidden_symbols(image))
            if evolution is None:
                check_client(image, rules, label, require)
                cases = [(BASE, name, False, expected) for name, expected in BASE_VALUES.items()]
                cases += [(CLIENT, name, False, expected) for name, expected in CLIENT_VALUES.items()]
            else:
                check_provider(image, rules, evolution, label, require)
                cases = [(PROVIDER, name, False, expected[evolution]) for name, expected in PROVIDER_VALUES.items()]
                cases += [(PROVIDER, name, True, expected[evolution]) for name, expected in PROVIDER_SCOPED.items()]
            values = [(module, scoped, expected, *position) for module, name, scoped, expected in cases
                      for position in positions(image, module, name, scoped)]
            for module, scoped, expected, function, value, compiled in values:
                decision, reason, wrong = judge(rules, value, scoped, compiled)
                passed = "indirectly" if compiled else "directly"
                decisions.setdefault(f"{module}.{function}", {}).setdefault(build, set()).add(
                    f"{decision}, passed {passed}")
                require(decision == expected, f"{label}: {function} is {decision} ({reason}), expected {expected}")
                require(not wrong, f"{label}: {function} is {decision} ({reason}) but passed {passed}")
                decision, reason, wrong = judge(hidden, value, scoped, compiled)
                require(not wrong, f"{label}, hidden symbols: {function} is {decision} ({reason}) but passed {passed}")
            for name in WEAKENED:
                for symbols in (image.exports, hidden_symbols(image)):
                    weakened = Rules(image, symbols, name)
                    disagreements[name] += sum(judge(weakened, value, scoped, compiled)[2]
                                               for _, scoped, _, _, value, compiled in values)
    for name, description in WEAKENED.items():
        require(disagreements[name], f"no compiled signature disagrees with the weakened rule '{description}', "
                                     "so the fixtures no longer exercise its guard")

    report = {"compiler": run("xcrun", "swiftc", "--version").strip(), "runtimeTested": False,
              "decisions": {case: {build: sorted(found) for build, found in rows.items()}
                            for case, rows in decisions.items()},
              "weakenedDisagreements": disagreements}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if problems:
        raise RuntimeError("\n".join(problems))


if __name__ == "__main__":
    main()
