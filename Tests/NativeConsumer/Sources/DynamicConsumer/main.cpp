#include <ABIBridge/ABIBridge.hpp>
#include <ABIBridge/Invocation.h>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdarg>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

struct Pair { double x, y; };
struct Nested { int16_t tag; Pair pair; void* context; };
extern "C" uint8_t dynamicTiny(uint8_t value) { return value ^ 0xff; }
extern "C" int8_t dynamicNegative() { return -42; }
extern "C" int32_t dynamicZero() { return 42; }
extern "C" double dynamicVariadic(float prefix, int count, ...) {
    va_list arguments;
    va_start(arguments, count);
    int integer = va_arg(arguments, int);
    double real = va_arg(arguments, double);
    void* pointer = va_arg(arguments, void*);
    Pair pair = va_arg(arguments, Pair);
    va_end(arguments);
    return prefix + count + integer + real + (pointer != nullptr) + pair.x + pair.y;
}
struct VariadicReceiver {
    __attribute__((noinline, used)) double run(int count, ...) const {
        va_list arguments;
        va_start(arguments, count);
        double value = va_arg(arguments, double);
        va_end(arguments);
        return count + value;
    }
};
extern "C" double dynamicMany(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e,
    int64_t f, int64_t g, int64_t h, int64_t i, int64_t j, double k, float l) {
    return a + b + c + d + e + f + g + h + i + j + k + l;
}
extern "C" void* dynamicPointer(void* pointer) { return pointer; }
extern "C" void dynamicStore(int32_t* value) { *value = 42; }
extern "C" Pair dynamicPair(Pair pair) { return {pair.x + 1, pair.y + 2}; }
extern "C" Nested dynamicNested(Nested value) {
    value.tag += 1;
    value.pair.x += 2;
    return value;
}

using Type = std::unique_ptr<ABIValueType, decltype(&ABIReleaseValueType)>;
using Call = std::unique_ptr<ABICallInterface, decltype(&ABIReleaseCallInterface)>;

Type scalar(int kind) {
    ABIResolutionFailure* failure = nullptr;
    Type type(ABICreateScalarType(kind, &failure), ABIReleaseValueType);
    assert(type && !failure);
    return type;
}
Type structure(std::initializer_list<const ABIValueType*> fields) {
    ABIResolutionFailure* failure = nullptr;
    Type type(ABICreateStructType(fields.begin(), fields.size(), &failure), ABIReleaseValueType);
    assert(type && !failure);
    return type;
}
Call call(const ABIValueType* result, std::initializer_list<const ABIValueType*> parameters) {
    ABIResolutionFailure* failure = nullptr;
    Call value(ABICreateCCallInterface(result, parameters.begin(), parameters.size(), &failure), ABIReleaseCallInterface);
    assert(value && !failure);
    return value;
}
void invoke(ABICallInterface* call, ABIUnmanagedFunction function, void* result, void* const* arguments) {
    ABIResolutionFailure* failure = nullptr;
    assert(ABIUnsafeInvokeCCallInterface(call, function, result, arguments, &failure));
    assert(!failure);
}

int main() {
    auto u8 = scalar(ABIValueUInt8);
    auto i8 = scalar(ABIValueInt8);
    auto i16 = scalar(ABIValueInt16);
    auto i32 = scalar(ABIValueInt32);
    auto i64 = scalar(ABIValueInt64);
    auto f32 = scalar(ABIValueFloat);
    auto f64 = scalar(ABIValueDouble);
    auto pointer = scalar(ABIValuePointer);
    auto unit = scalar(ABIValueVoid);

    auto pairType = structure({f64.get(), f64.get()});
    const ABIValueType* variadicTypes[] = {f32.get(), i32.get(), i8.get(), f32.get(), pointer.get(), pairType.get()};
    ABIResolutionFailure* variadicFailure = nullptr;
    Call variadic(ABICreateVariadicCCallInterface(f64.get(), variadicTypes, 6, 2, &variadicFailure), ABIReleaseCallInterface);
    assert(variadic && !variadicFailure);
    float prefix = 1.5f, real = 2.5f;
    int count = 4;
    int8_t integer = -7;
    int token = 0;
    void* context = &token;
    Pair variadicPair{3,4};
    void* variadicArguments[] = {&prefix, &count, &integer, &real, &context, &variadicPair};
    auto variadicSymbol = abi_bridge::Runtime::current().resolve(
        abi_bridge::declaration("dynamicVariadic", abi_bridge::language::c));
    const double expectedVariadic = dynamicVariadic(prefix, count, integer, real, context, variadicPair);
    double variadicResult = 0;
    invoke(variadic.get(), ABIUnsafeFunctionAtAddress(variadicSymbol.unsafe_address()), &variadicResult, variadicArguments);
    assert(variadicResult == expectedVariadic);
    abi_bridge::function<double(float, int, ...)> typedVariadic(variadicSymbol);
    assert(typedVariadic.unsafe_invoke(prefix, count, integer, real, context, variadicPair) == expectedVariadic);
    auto methodSymbol = abi_bridge::Runtime::current().resolve(
        abi_bridge::declaration("VariadicReceiver::run(int, ...) const", abi_bridge::language::cxx));
    abi_bridge::method<double(int, ...) const> variadicMethod(methodSymbol);
    auto receiver = std::make_shared<VariadicReceiver>();
    auto boundVariadic = variadicMethod.bind(receiver);
    assert(boundVariadic.unsafe_invoke(40, 2.0f) == receiver->run(40, 2.0f));
    auto callback = std::unique_ptr<ABICallClosure, decltype(&ABIReleaseCallClosure)>(
        ABICreateCallClosure(variadic.get(), [](void*, void* result, void* const* values) {
            auto pair = *static_cast<Pair*>(values[5]);
            *static_cast<double*>(result) = *static_cast<float*>(values[0]) + *static_cast<int*>(values[1])
                + *static_cast<int*>(values[2]) + *static_cast<double*>(values[3])
                + (*static_cast<void**>(values[4]) != nullptr) + pair.x + pair.y;
        }, nullptr, &variadicFailure), ABIReleaseCallClosure);
    assert(callback && !variadicFailure);
    invoke(variadic.get(), ABICallClosureFunction(callback.get()), &variadicResult, variadicArguments);
    assert(variadicResult == expectedVariadic);
    std::vector<std::thread> variadicWorkers;
    for (int index = 0; index < 4; ++index) variadicWorkers.emplace_back([&] {
        for (int iteration = 0; iteration < 20; ++iteration) {
            double result = 0;
            invoke(variadic.get(), ABIUnsafeFunctionAtAddress(variadicSymbol.unsafe_address()), &result, variadicArguments);
            assert(result == expectedVariadic);
        }
    });
    for (auto& worker : variadicWorkers) worker.join();
    ABIResolutionFailure* boundaryFailure = nullptr;
    assert(!ABICreateVariadicCCallInterface(f64.get(), variadicTypes, 6, 0, &boundaryFailure));
    assert(ABIResolutionFailureCode(boundaryFailure) == ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(boundaryFailure);

    auto tiny = call(u8.get(), {u8.get()});
    u8.reset();
    uint8_t input = 0x5a;
    void* arguments[] = {&input};
    uint8_t guarded[] = {0xcc, 0, 0xdd};
    auto symbol = abi_bridge::Runtime::current().resolve(
        abi_bridge::declaration("dynamicTiny", abi_bridge::language::c));
    invoke(tiny.get(), ABIUnsafeFunctionAtAddress(symbol.unsafe_address()), &guarded[1], arguments);
    assert(guarded[0] == 0xcc && guarded[1] == 0xa5 && guarded[2] == 0xdd);

    auto negative = call(i8.get(), {});
    int8_t signedResult = 0;
    invoke(negative.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicNegative), &signedResult, nullptr);
    assert(signedResult == -42);
    auto zero = call(i32.get(), {});
    int32_t zeroResult = 0;
    invoke(zero.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicZero), &zeroResult, nullptr);
    assert(zeroResult == 42);

    auto many = call(f64.get(), {i64.get(), i64.get(), i64.get(), i64.get(), i64.get(),
        i64.get(), i64.get(), i64.get(), i64.get(), i64.get(), f64.get(), f32.get()});
    int64_t integers[] = {1,2,3,4,5,6,7,8,9,10};
    double fraction = 1.5;
    float remainder = 0.5;
    void* manyArguments[] = {&integers[0],&integers[1],&integers[2],&integers[3],&integers[4],
        &integers[5],&integers[6],&integers[7],&integers[8],&integers[9],&fraction,&remainder};
    std::vector<std::thread> threads;
    for (int worker = 0; worker < 4; ++worker) {
        threads.emplace_back([&] {
            for (int iteration = 0; iteration < 20; ++iteration) {
                double result = 0;
                invoke(many.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicMany), &result, manyArguments);
                assert(result == 57.0);
            }
        });
    }
    for (auto& thread : threads) thread.join();

    auto pointerCall = call(pointer.get(), {pointer.get()});
    void* address = &zeroResult;
    void* pointerArguments[] = {&address};
    void* pointerResult = nullptr;
    invoke(pointerCall.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicPointer), &pointerResult, pointerArguments);
    assert(pointerResult == address);
    auto store = call(unit.get(), {pointer.get()});
    assert(ABIValueTypeSize(unit.get()) == 0);
    int32_t stored = 0;
    int32_t* destination = &stored;
    void* storeArguments[] = {&destination};
    invoke(store.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicStore), nullptr, storeArguments);
    assert(stored == 42);

    auto pair = structure({f64.get(), f64.get()});
    auto nested = structure({i16.get(), pair.get(), pointer.get()});
    assert(ABIValueTypeSize(nested.get()) == sizeof(Nested));
    assert(ABIValueTypeAlignment(nested.get()) == alignof(Nested));
    assert(ABIValueTypeFieldCount(nested.get()) == 3);
    assert(ABIValueTypeFieldOffset(nested.get(), 1) == offsetof(Nested, pair));
    assert(ABIValueTypeFieldOffset(nested.get(), 2) == offsetof(Nested, context));
    auto pairCall = call(pair.get(), {pair.get()});
    auto nestedCall = call(nested.get(), {nested.get()});
    threads.clear();
    for (int worker = 0; worker < 4; ++worker) {
        threads.emplace_back([&] {
            for (int iteration = 0; iteration < 20; ++iteration) {
                auto prepared = call(nested.get(), {nested.get()});
                Nested input{3, {4, 5}, address}, output{};
                void* values[] = {&input};
                invoke(prepared.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicNested), &output, values);
                assert(output.tag == 4 && output.pair.x == 6 && output.context == address);
            }
        });
    }
    for (auto& thread : threads) thread.join();
    pair.reset();
    nested.reset();
    f64.reset();
    Pair pairInput{2,3}, pairOutput{};
    void* pairArguments[] = {&pairInput};
    invoke(pairCall.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicPair), &pairOutput, pairArguments);
    assert(pairOutput.x == 3 && pairOutput.y == 5);
    Nested nestedInput{3, {4,5}, address}, nestedOutput{};
    void* nestedArguments[] = {&nestedInput};
    invoke(nestedCall.get(), reinterpret_cast<ABIUnmanagedFunction>(dynamicNested), &nestedOutput, nestedArguments);
    assert(nestedOutput.tag == 4 && nestedOutput.pair.x == 6 && nestedOutput.context == address);
    assert(nestedInput.tag == 3 && nestedInput.pair.x == 4);

    ABIResolutionFailure* failure = nullptr;
    const ABIValueType* invalidParameters[] = {unit.get()};
    assert(!ABICreateCCallInterface(i32.get(), invalidParameters, 1, &failure));
    assert(ABIResolutionFailureCode(failure) == ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(failure);
    failure = nullptr;
    assert(!ABIUnsafeInvokeCCallInterface(zero.get(), nullptr, &zeroResult, nullptr, &failure));
    assert(ABIResolutionFailureCode(failure) == ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(failure);
    std::cout << "Dynamic C ABI consumer passed: scalars, pointers, aggregates, storage, and concurrent reuse.\n";
}
