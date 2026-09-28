import CoreGraphics

@inline(never) public func echoClosureValue(_ callback: @escaping (Int64) -> Int64) -> (Int64) -> Int64 { callback }

public final class ClosureValueHolder {
    private let callback: (Int64) -> Int64
    init(_ callback: @escaping (Int64) -> Int64) { self.callback = callback }
    public func callAsFunction(_ value: Int64) -> Int64 { callback(value) }
}

@inline(never) public func callClosureValue(_ callback: (Int64) -> Int64, _ value: Int64) -> Int64 {
    callback(value)
}

@inline(never) public func holdClosureValue(_ callback: @escaping (Int64) -> Int64) -> ClosureValueHolder {
    ClosureValueHolder(callback)
}

@inline(never) public func makeStringClosureValue(_ prefix: String) -> (String) -> String {
    { prefix + $0 }
}

@inline(never) public func callRectClosureValue(_ callback: (CGRect) -> CGRect, _ value: CGRect) -> CGRect {
    callback(value)
}

@inline(never) public func callPointerClosureValue(
    _ callback: (UnsafePointer<Int64>?) -> Int64, _ value: UnsafePointer<Int64>?
) -> Int64 {
    callback(value)
}

@inline(never) public func callArrayClosureValue(
    _ callback: ([String]) -> [String], _ value: [String]
) -> [String] { callback(value) }

@inline(never) public func makeArrayClosureValue(_ suffix: String) -> ([String]) -> [String] {
    { $0 + [suffix] }
}

@inline(never) public func callOptionalArrayClosureValue(
    _ callback: ([String]?) -> [String]?, _ value: [String]?
) -> [String]? { callback(value) }

@inline(never) public func callOptionalStringClosureValue(
    _ callback: (String?) -> String?, _ value: String?
) -> String? { callback(value) }

@inline(never) public func makeOptionalStringClosureValue(_ suffix: String) -> (String?) -> String? {
    { $0.map { $0 + suffix } }
}

@inline(never) public func callVoidClosureValue(_ callback: () -> Void) {
    callback()
}
