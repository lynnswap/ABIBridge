public struct RuntimeRecord {
    public let object: AnyObject
    public let text: String
    private let cancellations: UnsafeMutablePointer<Int32>

    public init(object: AnyObject, text: String, cancellations: UnsafeMutablePointer<Int32>) {
        self.object = object
        self.text = text
        self.cancellations = cancellations
    }

    public var changed: AnyObject? { object }
    public func length() -> Int64 { Int64(text.count) }
    public func cancel() { cancellations.pointee += 1 }
}

@inline(never) public func visitRuntimeRecord(
    _ object: AnyObject, _ text: String, _ cancellations: UnsafeMutablePointer<Int32>,
    _ body: (RuntimeRecord) -> Void
) {
    let record = RuntimeRecord(object: object, text: text, cancellations: cancellations)
    for _ in 0..<3 { body(record) }
}

nonisolated(unsafe) private var savedRuntimeCallback: ((RuntimeRecord) -> Void)?
public func saveRuntimeCallback(_ body: @escaping (RuntimeRecord) -> Void) { savedRuntimeCallback = body }
public func clearRuntimeCallback() { savedRuntimeCallback = nil }
public func fireRuntimeCallback(_ object: AnyObject, _ text: String, _ cancellations: UnsafeMutablePointer<Int32>) {
    savedRuntimeCallback?(RuntimeRecord(object: object, text: text, cancellations: cancellations))
}

// A compiler-generated reference call for a consumer that cannot import RuntimeRecord.
public func referenceRuntimeRecord(_ object: AnyObject, _ text: String, _ cancellations: UnsafeMutablePointer<Int32>) -> String {
    var result = ""
    visitRuntimeRecord(object, text, cancellations) { record in
        result += record.text
        record.cancel()
    }
    return result
}
