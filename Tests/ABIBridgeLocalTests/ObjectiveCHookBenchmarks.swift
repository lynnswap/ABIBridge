import ABIBridge
import CoreGraphics
import Foundation
import ObjectiveC
import ObjectiveCFixtures
import Testing

private func withReplacement<Result, each Argument, Output>(
    _ entry: ObjCReplacement<Result, repeat each Argument>,
    on type: AnyClass = ABIReplacementFixture.self,
    selector: String,
    classMethod: Bool = false,
    body: () throws -> Output
) throws -> Output {
    let target = classMethod ? try #require(object_getClass(type)) : type
    let selector = NSSelectorFromString(selector)
    let method = try #require(class_getInstanceMethod(target, selector))
    let previous = method_getImplementation(method)
    class_replaceMethod(
        target,
        selector,
        entry.publishImplementation(),
        method_getTypeEncoding(method)
    )
    defer {
        class_replaceMethod(target, selector, previous, method_getTypeEncoding(method))
        entry.invalidate()
    }
    return try body()
}

@Suite(.serialized)
struct ObjectiveCHookBenchmarks {
    let runtime = ABIRuntime()

    @Test func managedEntryBenchmark() throws {
        let count = 10_000, object = ABIManagedHookFixture(), clock = ContinuousClock()
        func measure(_ name: String, _ body: () -> Void) {
            let start = clock.now
            autoreleasepool { for _ in 0..<count { body() } }
            print("Managed hook \(name), \(count) calls: \(start.duration(to: clock.now))")
        }
        // Prior tests may already have published inactive entries on this class.
        // A separate compiler-authored class remains a direct-call control.
        let direct = ABIHookBenchmarkControl()
        measure("scalar direct") { _ = direct.add(20, to: 22) }
        measure("CGSize direct") { _ = direct.resize(.zero) }
        measure("object direct") { _ = direct.object() }
        var tokens: [NativeObjCMethodHook] = []
        for level in 1...3 {
            tokens.append(
                try unsafe runtime.hookMethod(
                    on: ABIManagedHookFixture.self,
                    selector: "add:to:",
                    as: ((Int32, Int32) -> Int32).self,
                    onFailure: { Issue.record($0) }
                ) { call, a, b in try call.proceed(a, b) }
            )
            tokens.append(
                try unsafe runtime.hookMethod(
                    on: ABIManagedHookFixture.self,
                    selector: "resize:",
                    as: ((CGSize) -> CGSize).self,
                    onFailure: { Issue.record($0) }
                ) { call, value in try call.proceed(value) }
            )
            tokens.append(
                try unsafe runtime.hookMethod(
                    on: ABIManagedHookFixture.self,
                    selector: "object",
                    as: (() -> NSObject).self,
                    onFailure: { Issue.record($0) }
                ) { call in try call.proceed() }
            )
            measure("scalar \(level) hooks") { _ = object.add(20, to: 22) }
            measure("CGSize \(level) hooks") { _ = object.resize(.zero) }
            measure("object \(level) hooks") { _ = object.object() }
        }
        for token in tokens { token.invalidate() }
        measure("scalar inactive") { _ = object.add(20, to: 22) }
        measure("CGSize inactive") { _ = object.resize(.zero) }
        measure("object inactive") { _ = object.object() }
        #expect(object.liveResults == 0 && direct.liveResults == 0)
    }

    @Test func replacementEntryBenchmark() throws {
        let count = 10_000
        let receiver = ABIReplacementFixture()
        let clock = ContinuousClock()
        let start = clock.now
        for index in 0..<count { _ = receiver.add(Int32(index), to: 1) }
        let direct = start.duration(to: clock.now)
        let entry = try ObjCReplacement(
            on: ABIReplacementFixture.self,
            selector: "add:to:",
            as: ((Int32, Int32) -> Int32).self,
            onFailure: { Issue.record($0) }
        ) { call, a, b in try call.proceed(a, b) }
        try withReplacement(entry, selector: "add:to:") {
            let start = clock.now
            for index in 0..<count { _ = receiver.add(Int32(index), to: 1) }
            let callback = start.duration(to: clock.now)
            entry.invalidate()
            let bypassStart = clock.now
            for index in 0..<count { _ = receiver.add(Int32(index), to: 1) }
            print(
                "ObjC replacement \(count) calls: direct=\(direct), callback=\(callback), inactive=\(bypassStart.duration(to: clock.now))"
            )
        }
        let size = CGSize(width: 3, height: 5)
        let sizeStart = clock.now
        for _ in 0..<count { _ = receiver.resize(size) }
        let sizeDirect = sizeStart.duration(to: clock.now)
        let sizeEntry = try ObjCReplacement(
            on: ABIReplacementFixture.self,
            selector: "resize:",
            as: ((CGSize) -> CGSize).self,
            onFailure: { Issue.record($0) }
        ) { call, value in try call.proceed(value) }
        try withReplacement(sizeEntry, selector: "resize:") {
            let start = clock.now
            for _ in 0..<count { _ = receiver.resize(size) }
            print(
                "ObjC replacement CGSize \(count) calls: direct=\(sizeDirect), callback=\(start.duration(to: clock.now))"
            )
        }
        let objectStart = clock.now
        autoreleasepool { for _ in 0..<count { _ = receiver.object() } }
        let objectDirect = objectStart.duration(to: clock.now)
        let objectEntry = try ObjCReplacement(
            on: ABIReplacementFixture.self,
            selector: "object",
            as: (() -> NSObject).self,
            onFailure: { Issue.record($0) }
        ) { call in try call.proceed() }
        try withReplacement(objectEntry, selector: "object") {
            let start = clock.now
            autoreleasepool { for _ in 0..<count { _ = receiver.object() } }
            print(
                "ObjC replacement object \(count) calls: direct=\(objectDirect), callback=\(start.duration(to: clock.now))"
            )
        }
        #expect(receiver.liveResults == 0)
    }
}
