#!/usr/bin/env python3
"""Generate the SDK's @frozen @_addressableForDependencies declarations.

Such a declaration sets the addressable-for-dependencies value-witness bit for
itself, whatever it stores, so ABIBridge cannot read the bit as evidence of
resilience. The list is the union over the SDKs of every Xcode given with
--developer-dir (the selected Xcode by default), merged with the checked-in
list unless --replace is given. --check only verifies that the checked-in list
covers the selected SDKs.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/ABIBridge/SwiftSelfAddressableDeclarations.swift"
SDKS = ["macosx", "iphoneos", "appletvos", "watchos", "xros"]
# Members reset the attributes that precede them.
MEMBER = r"|(?P<member>\b(?:var|let|func|init|case|typealias|subscript|associatedtype)\b)"
DECLARATION = re.compile(
    r"\b(?:struct|enum|class|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)|\bextension\s+([A-Za-z_][\w:.]*)"
)


def sdk_paths(developer_dir):
    environment = dict(os.environ)
    if developer_dir:
        environment["DEVELOPER_DIR"] = developer_dir
    for sdk in SDKS:
        result = subprocess.run(["xcrun", "--sdk", sdk, "--show-sdk-path"],
                                capture_output=True, text=True, env=environment)
        if result.returncode == 0 and result.stdout.strip():
            yield Path(result.stdout.strip())


def interfaces(sdk):
    for path in sdk.rglob("*.swiftinterface"):
        if path.name.endswith(".private.swiftinterface") or ".package." in path.name:
            continue
        module = next((part[: -len(".swiftmodule")] for part in reversed(path.parts)
                       if part.endswith(".swiftmodule")), None)
        if module:
            yield module, path


def first_branches(text):
    """Keeps the first branch of each #if, which interfaces use for the newest
    compiler features, so that duplicated declaration headers stay balanced."""
    kept = []
    # Whether each enclosing #if is in its first branch.
    branches = []
    for line in text.splitlines():
        directive = line.strip()
        if directive.startswith("#if"):
            branches.append(True)
        elif directive.startswith(("#elseif", "#else")) and branches:
            branches[-1] = False
        elif directive.startswith("#endif") and branches:
            branches.pop()
        elif all(branches):
            kept.append(line)
    return "\n".join(kept)


def code(text):
    """Yields the text with comments and string literals blanked out."""
    result = []
    index = 0
    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = len(text) if end < 0 else end + 2
        elif text.startswith('"""', index):
            end = text.find('"""', index + 3)
            index = len(text) if end < 0 else end + 3
            result.append('""')
        elif text[index] == '"':
            end = index + 1
            while end < len(text) and text[end] not in '"\n':
                end += 2 if text[end] == "\\" else 1
            index = end + 1
            result.append('""')
        else:
            result.append(text[index])
            index += 1
    return "".join(result)


def qualified(module, written):
    """Names an extended type, which interfaces may qualify with module selectors."""
    components = [component.split("::")[-1] for component in written.split(".")]
    first = written.split(".")[0]
    owner = first.split("::")[0] if "::" in first else module
    if "::" not in first and len(components) > 1 and components[0] != module:
        owner = components.pop(0)
    elif "::" not in first and components and components[0] == module:
        components.pop(0)
    return ".".join([owner] + components)


def declarations(module, path):
    text = code(first_branches(path.read_text(errors="replace")))
    found = set()
    scopes = []
    pending = None
    attributes = ""
    for token in re.finditer(r"[{};]|@\w+|" + DECLARATION.pattern + MEMBER, text):
        value = token.group(0)
        if token.lastgroup == "member":
            attributes = ""
        elif value.startswith("@"):
            attributes += " " + value
        elif value == "{":
            scopes.append(pending)
            pending = None
            attributes = ""
        elif value == "}":
            if scopes:
                scopes.pop()
            attributes = ""
        elif value == ";":
            attributes = ""
        else:
            name, extended = token.group(1), token.group(2)
            path_names = [scope for scope in scopes if scope]
            if extended:
                pending = qualified(module, re.sub(r"<.*", "", extended))
            else:
                base = path_names[-1] if path_names else module
                pending = base + "." + name
                if "@frozen" in attributes and "@_addressableForDependencies" in attributes:
                    found.add(pending)
            attributes = ""
    return found


def scan(developer_dirs):
    found = set()
    for developer_dir in developer_dirs:
        for sdk in sdk_paths(developer_dir):
            for module, path in interfaces(sdk):
                found |= declarations(module, path)
    return found


def checked_in():
    if not OUTPUT.exists():
        return set()
    return set(re.findall(r'^\s+"([^"]+)",$', OUTPUT.read_text(), re.M))


def write(names):
    lines = "\n".join(f'    "{name}",' for name in sorted(names))
    OUTPUT.write_text(
        "// Generated by scripts/generate-swift-self-addressable-types.py from the\n"
        "// SDKs' .swiftinterface files. Regenerate it instead of editing it.\n\n"
        "/// `@frozen @_addressableForDependencies` declarations, which set the\n"
        "/// addressable-for-dependencies value-witness bit whatever they store.\n"
        "let swiftSelfAddressableDeclarations: Set<String> = [\n"
        f"{lines}\n"
        "]\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--developer-dir", action="append", default=[],
                        help="An Xcode Developer directory to scan; repeatable.")
    parser.add_argument("--replace", action="store_true",
                        help="Replace the checked-in list instead of extending it.")
    parser.add_argument("--check", action="store_true",
                        help="Fail if the checked-in list misses a declaration in the selected SDKs.")
    arguments = parser.parse_args()
    found = scan(arguments.developer_dir or [None])
    if not found:
        sys.exit("No @frozen @_addressableForDependencies declarations were found.")
    if arguments.check:
        missing = found - checked_in()
        if missing:
            sys.exit("Regenerate the self-addressable declarations; missing: " + ", ".join(sorted(missing)))
        print(f"{len(found)} self-addressable declarations are listed.")
        return
    write(found if arguments.replace else found | checked_in())
    print("\n".join(sorted(found)))


if __name__ == "__main__":
    main()
