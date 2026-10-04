package struct RuntimeErrorConvention: Sendable {
    package let type: RuntimeValueType
    package let isTyped: Bool
    package init(type: RuntimeValueType, isTyped: Bool) {
        self.type = type
        self.isTyped = isTyped
    }
}
