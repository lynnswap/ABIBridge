#include "CXXObjectFixtures.h"
#include <atomic>
#include <cstring>
#include <ptrauth.h>

const int32_t ABICXXFixtureData = 3;

namespace {
std::atomic<int32_t> counters{0};
std::atomic<int32_t> tokens{0};
}

namespace ABICXXFixture {
struct Token {
    int32_t value;
    explicit Token(int32_t value) : value(value) { ++tokens; }
    Token(const Token& other) : value(other.value) { ++tokens; }
    ~Token() { --tokens; }
};

class Counter {
    int32_t value;
public:
    explicit Counter(int32_t value) : value(value) { ++counters; }
    ~Counter() { --counters; }
    int32_t add(int32_t delta);
    int32_t current() const;
    int32_t *address();
    double many(int32_t a, int32_t b, int32_t c, int32_t d,
                int32_t e, int32_t f, int32_t g, int32_t h, double scale) const;
    Token transform(Token argument) const;
};
int32_t Counter::add(int32_t delta) { return value += delta; }
int32_t Counter::current() const { return value; }
int32_t *Counter::address() { return &value; }
double Counter::many(int32_t a, int32_t b, int32_t c, int32_t d,
                     int32_t e, int32_t f, int32_t g, int32_t h, double scale) const {
    return (value + a + b + c + d + e + f + g + h) * scale;
}
Token Counter::transform(Token argument) const { return Token(value + argument.value); }

struct Base {
    virtual int32_t value() const;
    int32_t primary = 10;
};
struct Secondary {
    virtual int32_t other() const;
    int32_t secondary = 20;
};
struct Derived : Base, Secondary {
    int32_t value() const override;
    int32_t other() const override;
};
int32_t Base::value() const { return primary; }
int32_t Secondary::other() const { return secondary; }
int32_t Derived::value() const { return primary + 100; }
int32_t Derived::other() const { return secondary + 200; }
}

void *ABICXXCreateCounter(int32_t value) { return new ABICXXFixture::Counter(value); }
void ABICXXDeleteCounter(void *value) { delete static_cast<ABICXXFixture::Counter *>(value); }
size_t ABICXXCounterSize() { return sizeof(ABICXXFixture::Counter); }
size_t ABICXXCounterAlignment() { return alignof(ABICXXFixture::Counter); }
int32_t ABICXXCounterLiveCount() { return counters.load(); }
void *ABICXXCreateToken(int32_t value) { return new ABICXXFixture::Token(value); }
void ABICXXDeleteToken(void *value) { delete static_cast<ABICXXFixture::Token *>(value); }
int32_t ABICXXTokenValue(const void *value) { return static_cast<const ABICXXFixture::Token *>(value)->value; }
int32_t ABICXXTokenLiveCount() { return tokens.load(); }

void *ABICXXTransformAdapter(ABICXXGenericFunction target, void *receiver, const void *argument) {
    using Method = ABICXXFixture::Token (*)(const ABICXXFixture::Counter *, ABICXXFixture::Token);
    auto method = reinterpret_cast<Method>(target);
    return new ABICXXFixture::Token(method(
        static_cast<const ABICXXFixture::Counter *>(receiver),
        *static_cast<const ABICXXFixture::Token *>(argument)));
}

void *ABICXXCreateDerived() { return new ABICXXFixture::Derived; }
void ABICXXDeleteDerived(void *value) { delete static_cast<ABICXXFixture::Derived *>(value); }
size_t ABICXXDerivedSize() { return sizeof(ABICXXFixture::Derived); }
size_t ABICXXDerivedAlignment() { return alignof(ABICXXFixture::Derived); }
size_t ABICXXSecondaryOffset(const void *value) {
    auto derived = static_cast<const ABICXXFixture::Derived *>(value);
    auto secondary = static_cast<const ABICXXFixture::Secondary *>(derived);
    return reinterpret_cast<const char *>(secondary) - reinterpret_cast<const char *>(derived);
}
size_t ABICXXSecondarySize() { return sizeof(ABICXXFixture::Secondary); }
size_t ABICXXSecondaryAlignment() { return alignof(ABICXXFixture::Secondary); }
int32_t ABICXXBaseOracle(const void *value) {
    return static_cast<const ABICXXFixture::Base *>(static_cast<const ABICXXFixture::Derived *>(value))->value();
}
int32_t ABICXXSecondaryOracle(const void *value) {
    return static_cast<const ABICXXFixture::Secondary *>(static_cast<const ABICXXFixture::Derived *>(value))->other();
}
uintptr_t ABICXXBaseVTableDiscriminator() {
#if __has_feature(ptrauth_calls)
    return ptrauth_string_discriminator("_ZTVN13ABICXXFixture4BaseE");
#else
    return 0;
#endif
}
uintptr_t ABICXXSecondaryVTableDiscriminator() {
#if __has_feature(ptrauth_calls)
    return ptrauth_string_discriminator("_ZTVN13ABICXXFixture9SecondaryE");
#else
    return 0;
#endif
}
uintptr_t ABICXXBaseSlotDiscriminator() {
#if __has_feature(ptrauth_calls)
    return ptrauth_string_discriminator("_ZNK13ABICXXFixture4Base5valueEv");
#else
    return 0;
#endif
}
uintptr_t ABICXXSecondarySlotDiscriminator() {
#if __has_feature(ptrauth_calls)
    return ptrauth_string_discriminator("_ZNK13ABICXXFixture9Secondary5otherEv");
#else
    return 0;
#endif
}
void ABICXXStoreSignedDataPointer(void *storage, const void *value) {
#if __has_feature(ptrauth_calls)
    value = ptrauth_sign_unauthenticated(value, ptrauth_key_asdb, ptrauth_blend_discriminator(storage, 0x1234));
#endif
    std::memcpy(storage, &value, sizeof(value));
}
