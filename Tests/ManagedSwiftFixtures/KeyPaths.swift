import Foundation
import Synchronization

public struct RuntimeKeyPathPayload: Equatable {
    public var text: String

    public init(_ text: String) { self.text = text }
}

public struct RuntimeKeyPathRoot {
    private var storage: RuntimeKeyPathPayload
    public private(set) var writes = 0

    public init(_ text: String) { storage = RuntimeKeyPathPayload(text) }

    public var payload: RuntimeKeyPathPayload {
        get { storage }
        set {
            storage = newValue
            writes += 1
        }
    }

    public var readOnly: String { storage.text }
}

public struct RuntimeKeyPathSequenceRoot {
    private var storage = [1]

    public init() {}

    public var sequence: any Sequence<Int> {
        get { storage }
        set { storage = Array(newValue) }
    }

    public var otherSequence: any Sequence<Int64> { [1] }
}

public func runtimePayloadKeyPath() -> AnyKeyPath { \RuntimeKeyPathRoot.payload }

public func validateRuntimePayloadKeyPath(
    _ keyPath: WritableKeyPath<RuntimeKeyPathRoot, RuntimeKeyPathPayload>
) -> Bool {
    let canonical = \RuntimeKeyPathRoot.payload
    var root = RuntimeKeyPathRoot("original")
    root[keyPath: keyPath] = RuntimeKeyPathPayload("updated")
    return keyPath == canonical && [canonical: true][keyPath] == true
        && root.payload.text == "updated" && root.writes == 1
}

public func writeRuntimePayload(through keyPath: AnyKeyPath, text: String) -> String? {
    guard let keyPath = keyPath as? WritableKeyPath<RuntimeKeyPathRoot, RuntimeKeyPathPayload>
    else { return nil }
    var root = RuntimeKeyPathRoot("original")
    root[keyPath: keyPath] = RuntimeKeyPathPayload(text)
    return "\(root[keyPath: keyPath].text):\(root.writes)"
}

extension String {
    public var runtimeKeyPathPayload: RuntimeKeyPathPayload {
        get { RuntimeKeyPathPayload(self) }
        set { self = newValue.text + "!" }
    }
}

public func runtimeExtensionPayloadKeyPath() -> AnyKeyPath { \String.runtimeKeyPathPayload }

public func writeRuntimeExtensionPayload(through keyPath: AnyKeyPath, text: String) -> String? {
    guard let keyPath = keyPath as? WritableKeyPath<String, RuntimeKeyPathPayload>
    else { return nil }
    var root = "original"
    root[keyPath: keyPath] = RuntimeKeyPathPayload(text)
    return root[keyPath: keyPath].text
}

@frozen public struct RuntimeKeyPathStoredRoot {
    public var number: Int

    public init(_ number: Int) { self.number = number }
}

public final class RuntimeKeyPathReferenceRoot {
    private var storage: String

    public init(_ text: String) { storage = text }

    public var text: String {
        get { storage }
        set { storage = newValue }
    }

    public var 🐱: String {
        get { storage }
        set { storage = newValue }
    }

    public var `deinit`: String {
        get { storage }
        set { storage = newValue }
    }
}

private let runtimeKeyPathTags = Mutex<[ObjectIdentifier: String]>([:])

extension NSObject {
    public var runtimeKeyPathTag: String {
        get { runtimeKeyPathTags.withLock { $0[ObjectIdentifier(self)] } ?? "untagged" }
        set { runtimeKeyPathTags.withLock { $0[ObjectIdentifier(self)] = newValue } }
    }
}

public final class RuntimeKeyPathObservedRoot: NSObject {
    private var storage = "original"

    @objc(nativeText) public dynamic var text: String {
        get { storage }
        set { storage = newValue }
    }
}

public func validateRuntimeObservedKeyPath(
    _ keyPath: ReferenceWritableKeyPath<RuntimeKeyPathObservedRoot, String>
) -> Bool {
    guard keyPath._kvcKeyPathString == "nativeText" else { return false }
    let receiver = RuntimeKeyPathObservedRoot()
    let observed = Mutex<[String]>([])
    let observation = receiver.observe(keyPath, options: [.new]) { _, change in
        if let value = change.newValue { observed.withLock { $0.append(value) } }
    }
    defer { observation.invalidate() }
    receiver[keyPath: keyPath] = "updated"
    return observed.withLock { $0 } == ["updated"]
        && keyPath == \RuntimeKeyPathObservedRoot.text
}
