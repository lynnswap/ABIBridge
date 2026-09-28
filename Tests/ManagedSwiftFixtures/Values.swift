public final class LifetimeToken {
    private let onDestroy: () -> Void

    public init(onDestroy: @escaping () -> Void = {}) { self.onDestroy = onDestroy }
    deinit { onDestroy() }
}

@frozen public struct ManagedRecord {
    public let token: LifetimeToken
    public let number: Int64

    public init(token: LifetimeToken, number: Int64) {
        self.token = token
        self.number = number
    }
}

// This target enables library evolution. Clients must not know this layout.
public struct ResilientRecord {
    private let payload: ManagedRecord

    public init(token: LifetimeToken, number: Int64) {
        payload = ManagedRecord(token: token, number: number)
    }

    public var token: LifetimeToken { payload.token }
    public var number: Int64 { payload.number }
}

@inline(never) public func transformManaged(_ value: ManagedRecord) -> ManagedRecord {
    ManagedRecord(token: value.token, number: value.number + 1)
}

@inline(never) public func transformOptional(_ value: Int64?) -> Int64? {
    value.map { $0 + 1 }
}

@inline(never) public func transformResilient(_ value: ResilientRecord) -> ResilientRecord {
    ResilientRecord(token: value.token, number: value.number + 1)
}
