import ABIBridgeRuntime
import Foundation

// Prepared once. Formatting an invocation must not touch its native frame or
// dereference arguments/receivers (including their custom descriptions).
func hookDescription(
    declaration: NativeDeclaration?,
    signature: Any.Type,
    unnamed: String
) -> String {
    let name: String
    if let declaration {
        if declaration.nameForm == .source {
            name = declaration.name
        } else {
            let raw = declaration.nameForm == .linker ? "_" + declaration.name : declaration.name
            name =
                DeclarationKey.demangle(raw, language: declaration.language.runtimeValue)
                ?? declaration.name
        }
    } else {
        name = unnamed
    }
    return name + " [" + String(reflecting: signature) + "]"
}
