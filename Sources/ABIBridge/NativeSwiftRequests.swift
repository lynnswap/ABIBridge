/// A native callable declaration and the language used to resolve it.
///
/// Language factories wrap typed declarations without performing lookup or
/// preparing a call. Save a request for later resolution, or
/// pass it directly to `resolve` or `resolveAndWait`. Scope and loading options
/// belong to resolution, and each returned handle retains its existing
/// invocation and ownership contract.
public struct NativeRequest<Declaration> {
    let declaration: Declaration
}

extension NativeRequest: Sendable where Declaration: Sendable {}

extension NativeRequest {
    /// Describes a Swift free function.
    ///
    /// Resolve this request with an `ABIRuntime` to get a
    /// ``NativeSwiftFunction``.
    public static func swift<Signature>(
        _ declaration: NativeSwiftFunctionRequest<Signature>
    ) -> Self where Declaration == NativeSwiftFunctionRequest<Signature> {
        Self(declaration: declaration)
    }

    /// Describes a Swift instance method, getter, or setter.
    ///
    /// Resolve this request with a ``NativeSwiftType`` for an explicit
    /// receiver, or a ``NativeObject`` to bind that object as the receiver.
    public static func swift<Signature>(
        _ declaration: NativeSwiftInstanceMemberRequest<Signature>
    ) -> Self where Declaration == NativeSwiftInstanceMemberRequest<Signature> {
        Self(declaration: declaration)
    }

    /// Describes a Swift initializer, or a static or class member.
    ///
    /// Resolve this request with a ``NativeSwiftType`` or ``NativeObject``
    /// to get a ``NativeSwiftFunction`` called on the lookup type.
    public static func swift<Signature>(
        _ declaration: NativeSwiftTypeMemberRequest<Signature>
    ) -> Self where Declaration == NativeSwiftTypeMemberRequest<Signature> {
        Self(declaration: declaration)
    }
}

/// How a Swift instance member receives `self`.
///
/// A request without a convention follows the member's default. Methods and
/// getters borrow `self`. A setter receives a value receiver inout, including
/// protocol `Self` without a class constraint, and a class-bound receiver as
/// a reference. Mutating and consuming members need an explicit convention,
/// because their symbols do not record it.
public enum NativeSwiftReceiverConvention: Sendable, Hashable {
    /// The member borrows `self`, as nonmutating methods and getters and
    /// `nonmutating` setters do.
    case borrowing
    /// The member receives `self` inout, as `mutating` members do.
    case mutating
    /// The member consumes `self`.
    ///
    /// Typed receivers transfer a copy; ``NativeSwiftValue`` transfers its
    /// owned value. A borrowed view cannot be consumed.
    case consuming
}

/// The options that every Swift declaration request accepts.
struct SwiftLookupOptions: Sendable {
    /// Type arguments introduced by the declaration itself.
    var genericArguments: [NativeSwiftGenericArgument] = []
    /// The formal function type, and optional canonical generic signature,
    /// when binary metadata is insufficient.
    var declaredSignature: String?
    /// Formal ABIs of closed nominal values in the lookup.
    var valueABIs: [NativeSwiftType: NativeType] = [:]
}

/// The Swift member a request names, and how lookup selects it.
struct SwiftMemberRequest: Sendable {
    enum Role: Sendable {
        case method, getter, setter, initializer
    }

    var role: Role
    /// Whether the member is a static or class member, called on the type.
    var isStatic: Bool
    /// The name as the caller wrote it: relative, protocol-qualified, or a
    /// complete declaration.
    var name: String
    var options: SwiftLookupOptions
}

/// How an instance member request passes `self`.
struct SwiftReceiverRequest: Sendable {
    /// Whether a value receiver passes inout; nil follows the declaration's
    /// default self convention.
    var isMutating: Bool?
    var isConsuming: Bool
    /// Explicit self ABI; nil uses the type representation or the declaration.
    var abi: NativeType?

    init(
        _ convention: NativeSwiftReceiverConvention?,
        role: SwiftMemberRequest.Role,
        abi: NativeType?
    ) {
        switch convention {
        // Only a setter's default depends on its declaration.
        case nil: isMutating = role == .setter ? nil : false
        case .borrowing?, .consuming?: isMutating = false
        case .mutating?: isMutating = true
        }
        isConsuming = convention == .consuming
        self.abi = abi
    }
}

/// A Swift free function to prepare for calls.
///
/// Wrap the declaration with `NativeRequest.swift`, then use
/// `ABIRuntime`'s `resolveAndWait(_:in:loading:)` or
/// `resolve(_:in:loading:)` to get a ``NativeSwiftFunction``. A request holds
/// no image scope, so one request can be resolved in several scopes.
///
/// A label-only name, such as `Example.decorate(_:)`, selects the declaration
/// whose native signature accepts the requested types. A complete demangled
/// declaration selects exactly that declaration; the requested types may then
/// adapt it, provided they lower as the declared types do.
public struct NativeSwiftFunctionRequest<Signature>: Sendable {
    let name: String
    let options: SwiftLookupOptions

    /// Describes a free function.
    ///
    /// - Parameters:
    ///   - name: A qualified label-only name, such as `Example.decorate(_:)`,
    ///     or a complete demangled declaration.
    ///   - signature: The complete Swift function type, including native
    ///     error and async isolation conventions.
    ///   - genericArguments: Scalar types and packs in declaration parameter
    ///     order.
    ///   - declaredSignature: The formal function type and optional canonical
    ///     generic signature when binary metadata is insufficient. It can state
    ///     result dependencies with `@_lifetime(borrow name)` using each
    ///     parameter's internal name. Omitting the attribute leaves the
    ///     dependencies unknown.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup,
    ///     runtime-only or host types, such as structs and enums whose
    ///     conventions ABIBridge cannot infer from their metadata. They take
    ///     precedence over conformances and inferred conventions where the
    ///     signature names their types, but inference does not consult them
    ///     for the fields of a value it lowers. Inside an Optional, an entry
    ///     describes only the declaration's own type, not an adapter host
    ///     type, whose Optional can have another layout. An entry for an
    ///     Optional itself must pass as Swift passes that Optional when
    ///     ABIBridge establishes its payload's convention.
    public static func function(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) -> Self {
        Self(
            name: name,
            options: .init(
                genericArguments: genericArguments,
                declaredSignature: declaredSignature,
                valueABIs: valueABIs
            )
        )
    }
}

/// A Swift instance method, or a property's or subscript's getter or setter,
/// to prepare for calls.
///
/// Wrap the declaration with `NativeRequest.swift`, then resolve it on a
/// ``NativeSwiftType`` to get a ``NativeSwiftMethod``,
/// which takes its receiver at each call, or on a ``NativeObject`` to get a
/// ``NativeBoundSwiftMethod`` bound to that object. The same request resolves
/// on either, with the same options.
///
/// A name can be relative to the type, such as `start()` or `text`; qualified
/// by a protocol, such as `Example.Shape.area()`, to select a requirement or
/// else a protocol extension member; or a complete declaration, such as
/// `chromeView.getter : Example.ChromeView` or
/// `(extension in Example):Example.Renderable.summary() -> Swift.String`.
/// A label-only name selects the declaration whose native signature accepts
/// the requested types. A complete declaration selects that declaration, and
/// the requested types may adapt it.
///
/// The signature is the complete function type of the call, excluding `self`:
/// `() -> Value` for a property getter, `(Value) -> Void` for a property
/// setter, `(Index) -> Value` for a subscript getter, and
/// `(Value, Index) -> Void` for a subscript setter. A subscript's accessors
/// are the getter and setter of the member named `subscript`.
///
/// See <doc:SwiftMemberInvocation> for lookup order, dispatch, and receiver
/// ownership.
public struct NativeSwiftInstanceMemberRequest<Signature>: Sendable {
    let member: SwiftMemberRequest
    let receiver: SwiftReceiverRequest

    private init(
        _ role: SwiftMemberRequest.Role,
        name: String,
        genericArguments: [NativeSwiftGenericArgument],
        declaredSignature: String?,
        valueABIs: [NativeSwiftType: NativeType],
        receiverABI: NativeType?,
        receiver convention: NativeSwiftReceiverConvention?
    ) {
        member = .init(
            role: role,
            isStatic: false,
            name: name,
            options: .init(
                genericArguments: genericArguments,
                declaredSignature: declaredSignature,
                valueABIs: valueABIs
            )
        )
        receiver = .init(convention, role: role, abi: receiverABI)
    }

    /// Describes an instance method.
    ///
    /// - Parameters:
    ///   - name: A relative, protocol-qualified, or complete method name.
    ///   - signature: Explicit arguments and result, excluding `self`, with
    ///     native error and async isolation conventions.
    ///   - genericArguments: Type arguments introduced by the method.
    ///   - declaredSignature: The formal function type and optional canonical
    ///     generic signature when binary metadata is insufficient. It can state
    ///     result dependencies with `@_lifetime(borrow name)`; use each
    ///     parameter's internal name, or `self` for an instance member.
    ///     Omitting the attribute leaves the dependencies unknown.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup that
    ///     ABIBridge cannot infer from their metadata, as for
    ///     ``NativeSwiftFunctionRequest/function(_:as:genericArguments:declaredAs:valueABIs:)``.
    ///   - receiverABI: Explicit `self` ABI; nil uses the type representation
    ///     or generic declaration. For an Optional `self` that the declaration
    ///     passes by value, it must describe the Optional's enum storage; a
    ///     mutating `self`, or the `self` of a generic extension, passes by
    ///     address.
    ///   - convention: How the method receives `self`; nil borrows it.
    public static func method(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        receiver convention: NativeSwiftReceiverConvention? = nil
    ) -> Self {
        Self(
            .method,
            name: name,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs,
            receiverABI: receiverABI,
            receiver: convention
        )
    }

    /// Describes a property or subscript getter.
    ///
    /// Use `(() -> Value).self` for a synchronous, nonthrowing property, and
    /// include the getter's native error, async, and isolation conventions
    /// when present. For a throwing generic getter, `declaredSignature`
    /// supplies the source function type, such as `"() throws(B) -> A"`,
    /// because getter symbols omit the formal error type.
    ///
    /// - Parameters:
    ///   - name: A property name, `subscript`, or a complete getter
    ///     declaration, relative, protocol-qualified, or extension-qualified.
    ///   - signature: `() -> Value` for a property, or the subscript's
    ///     indices and value, such as `(Int) -> Value`.
    ///   - genericArguments: Type arguments introduced by a generic subscript.
    ///   - declaredSignature: The formal getter type and optional canonical
    ///     generic signature.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup.
    ///   - receiverABI: Explicit `self` ABI, as for
    ///     ``method(_:as:genericArguments:declaredAs:valueABIs:receiverABI:receiver:)``.
    ///   - convention: How the getter receives `self`; nil borrows it.
    public static func getter(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        receiver convention: NativeSwiftReceiverConvention? = nil
    ) -> Self {
        Self(
            .getter,
            name: name,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs,
            receiverABI: receiverABI,
            receiver: convention
        )
    }

    /// Describes a property or subscript setter.
    ///
    /// A setter consumes its incoming value. Without a convention, a value
    /// receiver passes inout and a class-bound receiver as a reference; a
    /// protocol setter with a concrete same-type `Self` receives `self` inout,
    /// even when that type is a class. Pass ``NativeSwiftReceiverConvention/borrowing``
    /// for a `nonmutating` setter.
    ///
    /// - Parameters:
    ///   - name: A property name, `subscript`, or a complete setter
    ///     declaration, relative, protocol-qualified, or extension-qualified.
    ///   - signature: `(Value) -> Void` for a property, or the new value
    ///     followed by the subscript's indices, such as `(Value, Int) -> Void`.
    ///   - genericArguments: Type arguments introduced by a generic subscript.
    ///   - declaredSignature: The formal setter type and optional canonical
    ///     generic signature.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup.
    ///   - receiverABI: Explicit `self` ABI, as for
    ///     ``method(_:as:genericArguments:declaredAs:valueABIs:receiverABI:receiver:)``.
    ///   - convention: How the setter receives `self`; nil follows its
    ///     declaration's default.
    public static func setter(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:],
        receiverABI: NativeType? = nil,
        receiver convention: NativeSwiftReceiverConvention? = nil
    ) -> Self {
        Self(
            .setter,
            name: name,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs,
            receiverABI: receiverABI,
            receiver: convention
        )
    }
}

/// A Swift initializer, or a static or class method, getter, or setter, to
/// prepare for calls.
///
/// Wrap the declaration with `NativeRequest.swift`, then resolve it on a
/// ``NativeSwiftType``, or on a ``NativeObject`` for
/// the object's type, to get a ``NativeSwiftFunction``. The type's metadata
/// is supplied as `self` where the declaration receives a thick metatype;
/// concrete struct and enum type members have no metatype `self` argument.
///
/// Names follow the rules of ``NativeSwiftInstanceMemberRequest``. A name
/// qualified by a protocol, such as `Example.Shape.make()` or
/// `Example.Shape.init(size:)`, selects the requirement for this type's
/// conformance and receives this type as `Self`.
public struct NativeSwiftTypeMemberRequest<Signature>: Sendable {
    let member: SwiftMemberRequest

    private init(
        _ role: SwiftMemberRequest.Role,
        name: String,
        genericArguments: [NativeSwiftGenericArgument],
        declaredSignature: String?,
        valueABIs: [NativeSwiftType: NativeType]
    ) {
        member = .init(
            role: role,
            isStatic: role != .initializer,
            name: name,
            options: .init(
                genericArguments: genericArguments,
                declaredSignature: declaredSignature,
                valueABIs: valueABIs
            )
        )
    }

    /// Describes an allocating initializer.
    ///
    /// Ordinary initializer arguments transfer ownership to the callee. The
    /// native metadata is supplied automatically, and the result uses the
    /// requested Swift class or value adapter. ``NativeSwiftBorrowing``
    /// selects an explicitly borrowed initializer parameter. A
    /// protocol-qualified initializer requirement constructs this type
    /// through its conformance and returns `Self` indirectly.
    ///
    /// - Parameters:
    ///   - name: A relative initializer name, such as `init(text:)`, or one
    ///     qualified by a protocol.
    ///   - signature: Explicit arguments and the constructed result.
    ///   - genericArguments: Type arguments introduced by the initializer.
    ///   - declaredSignature: The formal function type and optional canonical
    ///     generic signature when binary metadata is insufficient. It can state
    ///     result dependencies with `@_lifetime(borrow name)` using each
    ///     parameter's internal name. Omitting the attribute leaves the
    ///     dependencies unknown.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup.
    public static func initializer(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) -> Self {
        Self(
            .initializer,
            name: name,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        )
    }

    /// Describes a static or class method.
    ///
    /// - Parameters:
    ///   - name: A relative, protocol-qualified, or complete method name.
    ///   - signature: Explicit arguments and result.
    ///   - genericArguments: Type arguments introduced by the method.
    ///   - declaredSignature: The formal function type and optional canonical
    ///     generic signature when binary metadata is insufficient. It can state
    ///     result dependencies with `@_lifetime(borrow name)` using each
    ///     parameter's internal name. Omitting the attribute leaves the
    ///     dependencies unknown.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup.
    public static func staticMethod(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) -> Self {
        Self(
            .method,
            name: name,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        )
    }

    /// Describes a static or class property or subscript getter.
    ///
    /// - Parameters:
    ///   - name: A property name, `subscript`, or a complete getter
    ///     declaration.
    ///   - signature: `() -> Value` for a property, or the subscript's
    ///     indices and value, with native error, async, and isolation
    ///     conventions.
    ///   - genericArguments: Type arguments introduced by a generic subscript.
    ///   - declaredSignature: The formal getter type and optional canonical
    ///     generic signature.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup.
    public static func staticGetter(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) -> Self {
        Self(
            .getter,
            name: name,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        )
    }

    /// Describes a static or class property or subscript setter, which
    /// consumes its incoming value.
    ///
    /// - Parameters:
    ///   - name: A property name, `subscript`, or a complete setter
    ///     declaration.
    ///   - signature: `(Value) -> Void` for a property, or the new value
    ///     followed by the subscript's indices.
    ///   - genericArguments: Type arguments introduced by a generic subscript.
    ///   - declaredSignature: The formal setter type and optional canonical
    ///     generic signature.
    ///   - valueABIs: Formal ABIs for closed nominal values in this lookup.
    public static func staticSetter(
        _ name: String,
        as signature: Signature.Type,
        genericArguments: [NativeSwiftGenericArgument] = [],
        declaredAs declaredSignature: String? = nil,
        valueABIs: [NativeSwiftType: NativeType] = [:]
    ) -> Self {
        Self(
            .setter,
            name: name,
            genericArguments: genericArguments,
            declaredSignature: declaredSignature,
            valueABIs: valueABIs
        )
    }
}
