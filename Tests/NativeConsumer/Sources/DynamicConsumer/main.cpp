#include <ABIBridge/ABIBridge.hpp>
#include <ABIBridge/Invocation.h>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

struct Pair { double x, y; };
struct Nested { int16_t tag; Pair pair; void* context; };
extern "C" uint8_t dynamicTiny(uint8_t value) { return value ^ 0xff; }
extern "C" int8_t dynamicNegative() { return -42; }
extern "C" int32_t dynamicZero() { return 42; }
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
