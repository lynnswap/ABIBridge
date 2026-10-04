import ABIBridge
import ArchitectureFixtures
import CoreGraphics
import Foundation
import Synchronization

private final class AggregateHookFailures: Sendable {
    let messages = Mutex<[String]>([])
    func append(_ error: any Error) { messages.withLock { $0.append(String(describing: error)) } }
    var isEmpty: Bool { messages.withLock { $0.isEmpty } }
}
#if canImport(UIKit)
import UIKit

@MainActor private final class InsetsReceiver: NSObject {
    @objc dynamic func insets(_ value: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: value.top + 1, left: value.left + 2,
                     bottom: value.bottom + 3, right: value.right + 4)
    }
    @objc dynamic func directional(_ value: NSDirectionalEdgeInsets) -> NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(top: value.top + 1, leading: value.leading + 2,
                                bottom: value.bottom + 3, trailing: value.trailing + 4)
    }
}
#endif

@MainActor private final class TransformReceiver: NSObject {
    @objc dynamic func transform(_ value: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: value.a, b: value.b, c: value.c, d: value.d, tx: value.tx + 3, ty: value.ty + 4)
    }
}

@MainActor func validateObjectiveCValues() throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let format = "%.1f/%d/%@" as NSString
    let variadic = try runtime.object(NSString.self as AnyObject).method(selector: "stringWithFormat:",
        as: ((NSString, Float, Int8, NSString) -> NSString).self, variadicFrom: 1)
    try check(try unsafe variadic.unsafeInvoke(format, 1.5, -3, "device") == "1.5/-3/device",
        "Variadic Objective-C current dispatch promotes scalar and object tails with PAC")
    let capturedFormat = try runtime.objcImplementation(on: NSString.self, selector: "stringWithFormat:",
        as: ((NSString, Float, Int8, NSString) -> NSString).self, variadicFrom: 1, classMethod: true)
    try check(try unsafe capturedFormat.unsafeInvoke(on: NSString.self as AnyObject, format, 2.5, -4, "captured") == "2.5/-4/captured",
        "Variadic captured IMP preserves its authenticated pointer")
    let ownership = ABIValidationOwnershipFixture()
    let options = NativeMethodOptions(consumedArguments: [0])
    let consume = try runtime.object(ownership).method(selector: "consume:",
        as: ((NSObject?) -> Int).self, options: options)
    let consumeMessage = try runtime.objcMethod(on: ABIValidationOwnershipFixture.self,
        selector: "consume:", as: ((NSObject?) -> Int).self, options: options)
    let consumeCaptured = try runtime.objcImplementation(on: ABIValidationOwnershipFixture.self,
        selector: "consume:", as: ((NSObject?) -> Int).self, options: options)
    typealias Block = @convention(block) (Int) -> Int
    let consumeBlock = try runtime.object(ownership).method(selector: "consumeBlock:value:",
        as: ((Block?, Int) -> Int).self, options: options)
    let echoCF = try runtime.object(ownership).method(selector: "echoCFValue:",
        as: ((Unmanaged<NSObject>?) -> Unmanaged<NSObject>?).self)
    weak var observedValue: NSObject?
    try autoreleasepool {
        let value = ownership.copyValue()
        observedValue = value
        try check(ownership.consume(value) == 1, "Compiler caller supplies consumed object ownership")
        try check(try unsafe consume.unsafeInvoke(value) == 1, "Bound message supplies an independent consumed argument")
        try check(try unsafe consumeMessage.unsafeInvoke(on: ownership, value) == 1, "Receiver-independent message preserves consumed ownership")
        try check(try unsafe consumeCaptured.unsafeInvoke(on: ownership, value) == 1, "Captured IMP preserves consumed ownership with PAC")
        let block: Block = { [value] number in withExtendedLifetime(value) { number + 1 } }
        try check(try unsafe consumeBlock.unsafeInvoke(block, 41) == 42, "Consumed object-encoded block preserves caller captures")
        try check(try unsafe echoCF.unsafeInvoke(.passUnretained(value))?.takeUnretainedValue() === value,
            "Unmanaged Core Foundation references use their native pointer representation")
        let failures = AggregateHookFailures()
        let hook = try unsafe runtime.hookMethod(on: ABIValidationOwnershipFixture.self, selector: "consume:",
            as: ((NSObject?) -> Int).self, options: options, onFailure: { failures.append($0) }) { call, input in
                try call.proceed(input) + call.proceed(input)
            }
        defer { hook.invalidate() }
        try check(ownership.consume(value) == 2 && failures.isEmpty,
            "Repeated hook continuations each transfer independent consumed ownership")
    }
    try check(observedValue == nil && ownership.liveValues == 0 && ownership.calls == 6,
        "Consumed arguments and hook captures release after their final caller ownership")
    let receiver = TransformReceiver()
    let input = CGAffineTransform(a: 1, b: 2, c: 3, d: 4, tx: 5, ty: 6)
    let method = try runtime.object(receiver).method(selector: "transform:",
        as: ((CGAffineTransform) -> CGAffineTransform).self)
    try check(try unsafe method.unsafeInvoke(input) == receiver.transform(input),
              "CGAffineTransform uses the Objective-C runtime aggregate layout")
    let message = try runtime.objcMethod(on: TransformReceiver.self, selector: "transform:",
        as: ((CGAffineTransform) -> CGAffineTransform).self)
    try check(try unsafe message.unsafeInvoke(on: receiver, input) == receiver.transform(input),
              "Receiver-independent transform message follows compiler dispatch")
    weak var observed: TransformReceiver?
    var bound: NativeBoundObjCMethod<CGAffineTransform, CGAffineTransform>?
    do {
        let temporary = TransformReceiver()
        observed = temporary
        bound = try message.bind(to: temporary)
    }
    try check(observed != nil, "Explicit binding retains its receiver")
    try check(try unsafe bound!.unsafeInvoke(input) == receiver.transform(input), "Bound copy shares the prepared signature")
    bound = nil
    try check(observed == nil, "Unbound message does not prolong the released receiver")
    let captured = try runtime.objcImplementation(on: TransformReceiver.self, selector: "transform:",
        as: ((CGAffineTransform) -> CGAffineTransform).self)
    try check(try unsafe captured.unsafeInvoke(on: receiver, input) == receiver.transform(input),
              "Captured aggregate implementation agrees with compiler dispatch")

#if canImport(UIKit)
    let insetsReceiver = InsetsReceiver()
    let insets = UIEdgeInsets(top: 1, left: 2, bottom: 3, right: 4)
    let ordinary = try runtime.object(insetsReceiver).method(selector: "insets:",
        as: ((UIEdgeInsets) -> UIEdgeInsets).self)
    try check(try unsafe ordinary.unsafeInvoke(insets) == insetsReceiver.insets(insets),
              "UIEdgeInsets arguments and results need no ABIBridge registration")
    let unboundInsets = try runtime.objcMethod(on: InsetsReceiver.self, selector: "insets:",
        as: ((UIEdgeInsets) -> UIEdgeInsets).self)
    try check(try unsafe unboundInsets.unsafeInvoke(on: insetsReceiver, insets) == insetsReceiver.insets(insets),
              "Unbound UIEdgeInsets message preserves aggregate ABI")
    let implementation = try runtime.objcImplementation(on: InsetsReceiver.self, selector: "insets:",
        as: ((UIEdgeInsets) -> UIEdgeInsets).self)
    try check(try unsafe implementation.unsafeInvoke(on: insetsReceiver, insets) == insetsReceiver.insets(insets),
              "Captured UIEdgeInsets uses the native floating register classification")
    let directional = try runtime.object(insetsReceiver).method(selector: "directional:",
        as: ((NSDirectionalEdgeInsets) -> NSDirectionalEdgeInsets).self)
    let value = NSDirectionalEdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
    let result = try unsafe directional.unsafeInvoke(value)
    try check(result.top == 2 && result.leading == 4 && result.bottom == 6 && result.trailing == 8,
              "NSDirectionalEdgeInsets shares the same generic structure path")
    let failures = AggregateHookFailures()
    let hook = try unsafe runtime.hookMethod(on: InsetsReceiver.self, selector: "insets:",
        as: ((UIEdgeInsets) -> UIEdgeInsets).self, onFailure: { failures.append($0) }) { call, value in
            var result = try call.proceed(value)
            result.top += 100
            return result
        }
    defer { hook.invalidate() }
    let current = try unsafe unboundInsets.unsafeInvoke(on: insetsReceiver, insets)
    try check(current.top == 102 && current.right == 8, "Prepared unbound message observes a later managed hook")
    let hooked = insetsReceiver.insets(insets)
    try check(hooked.top == 102 && hooked.right == 8 && failures.isEmpty, "Managed callback round-trips UIEdgeInsets through the native ABI")
#endif
    return checks
}
