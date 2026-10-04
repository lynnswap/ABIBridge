@inline(never) public func add(_ left: Int64, _ right: Int64) -> Int64 { left + right }
@inline(never) public func identity<T>(_ value: T) -> T { value }
@inline(never) public func hashEcho<T: Hashable>(_ value: T) -> T { value }
@inline(never) public func apply(_ callback: (Int64) -> Int64, _ value: Int64) -> Int64 {
    callback(value)
}
