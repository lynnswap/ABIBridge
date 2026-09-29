import ABIBridge
import Darwin
import Foundation

struct ForeignPoint: ABIBridgeValue {
    static let abiType = try! NativeType.structure(
        named: "SwiftFunctionFixture.Point", fields: [.double, .double]
    )
    var x, y: Double
    init(nativeValue: NativeValue) throws {
        x = try unsafe nativeValue.field(at: 0).read(as: Double.self)
        y = try unsafe nativeValue.field(at: 1).read(as: Double.self)
    }
    static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: (value.x, value.y), as: abiType)
    }
}

@MainActor
func prepare(_ path: String, extensionPath: String) async throws -> [NativeBoundSwiftMethod<Int, Int>] {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        fatalError(String(cString: dlerror()))
    }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let scope = ImageSelector.path(URL(fileURLWithPath: path))
    let type = try await runtime.swiftType(named: "SwiftFunctionFixture.Renderer", in: scope)
    let initialize = try await type.initializer(
        named: "init(text:)", as: ((String) -> AnyObject).self
    )
    let object = try unsafe initialize.unsafeInvoke("initial")
    let setText = try await type.setter(named: "text", as: String.self)
    try unsafe setText.unsafeInvoke(on: object, "ready")
    let getText = try await type.getter(named: "text", as: String.self)
    let text = try unsafe getText.unsafeInvoke(on: object)
    precondition(text == "ready")
    let standard = try await type.staticGetter(named: "standard", as: String.self)
    let standardText = try unsafe standard.unsafeInvoke()
    precondition(standardText == "standard")

    let pointType = try await runtime.swiftType(
        named: "SwiftFunctionFixture.Point", as: ForeignPoint.self, in: type.image
    )
    let pointInitializer = try await pointType.initializer(
        named: "init(x:y:)", as: ((Double, Double) -> ForeignPoint).self
    )
    var point = try unsafe pointInitializer.unsafeInvoke(2, 3)
    let setX = try await pointType.setter(named: "x", as: Double.self)
    try unsafe setX.unsafeInvoke(on: &point, 4)
    let sum = try await pointType.method(named: "sum(_:)", as: ((Double) -> Double).self)
    let total = try unsafe sum.unsafeInvoke(on: point, 5)
    precondition(total == 12 && point.x == 4)

    guard let extensionImage = dlopen(extensionPath, RTLD_NOW | RTLD_LOCAL) else {
        fatalError(String(cString: dlerror()))
    }
    defer { dlclose(extensionImage) }
    let bound = try await runtime.object(object).method(named: "extendedScore(_:)", as: ((Int) -> Int).self)
    let makePrivate = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.makePrivateRenderer(_:)", as: ((Int) -> AnyObject).self, in: scope
    )
    let privateReceiver = try unsafe makePrivate.unsafeInvoke(40)
    let privateBound = try await runtime.object(privateReceiver).method(named: "score(_:)", as: ((Int) -> Int).self)
    let makeGeneric = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.makeGenericRenderer(_:)", as: ((Int) -> AnyObject).self, in: scope
    )
    let genericReceiver = try unsafe makeGeneric.unsafeInvoke(41)
    let genericBound = try await runtime.object(genericReceiver).method(named: "score(_:)", as: ((Int) -> Int).self)
    let genericGetter = try await runtime.object(genericReceiver).getter(named: "currentScore", as: Int.self)
    let genericValue = try unsafe genericGetter.unsafeInvoke()
    precondition(genericValue == 41)
    let makeConstrained = try await runtime.swiftFunction(
        named: "SwiftFunctionFixture.makeConstrainedRenderer(_:)", as: ((Int) -> AnyObject).self, in: scope
    )
    let constrainedReceiver = try unsafe makeConstrained.unsafeInvoke(40)
    let constrained = try await runtime.object(constrainedReceiver).method(
        named: "constrainedScore(_:)", as: ((Int) -> Int).self
    )
    let constrainedGetter = try await runtime.object(constrainedReceiver).getter(named: "constrainedValue", as: Int.self)
    let constrainedValue = try unsafe constrainedGetter.unsafeInvoke()
    precondition(constrainedValue == 40)
    await runtime.removeCachedResults()
    return [bound, privateBound, genericBound, constrained]
}

let methods = try await prepare(CommandLine.arguments[1], extensionPath: CommandLine.arguments[2])
let value = try unsafe methods[0].unsafeInvoke(36)
precondition(value == 42)
let privateValue = try unsafe methods[1].unsafeInvoke(2)
precondition(privateValue == 42)
let genericValue = try unsafe methods[2].unsafeInvoke(1)
precondition(genericValue == 42)
let constrainedValue = try unsafe methods[3].unsafeInvoke(2)
precondition(constrainedValue == 42)
print("Swift member consumer passed: public, extension, private, generic, and constrained receiver methods")
