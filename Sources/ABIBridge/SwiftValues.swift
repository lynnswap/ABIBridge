import ABIBridgeCore
import ABIBridgeRuntime

// Array, Dictionary, and Set each hold one storage reference regardless of
// their element types, so they are passed as one pointer.
protocol SwiftCollectionValue {
    /// The standard substitution that mangles the collection's declaration.
    static var mangledDeclaration: String { get }
}
extension Array: SwiftCollectionValue { static var mangledDeclaration: String { "Sa" } }
extension Dictionary: SwiftCollectionValue { static var mangledDeclaration: String { "SD" } }
extension Set: SwiftCollectionValue { static var mangledDeclaration: String { "Sh" } }
