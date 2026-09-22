#include "FixtureTypes.hpp"

namespace ABIBridgeFixture {
int add(int left, int right) { return left + right; }
double multiply(double left, double right) { return left * right; }
void increment(int& value) { ++value; }
int& identity(int& value) { return value; }
std::string greet(std::string name) { return "Hello, " + name; }
std::string consume(std::string&& value) {
    auto result = std::move(value);
    value = "consumed";
    return result;
}
LargeResult large(long value) {
    return {{value, value + 1, value + 2, value + 3, value + 4, value + 5, value + 6, value + 7}};
}
int counter = 42;

int Counter::add(int delta) { return value += delta; }
int Counter::current() const { return value; }
int& Counter::reference() { return value; }
std::string Counter::describe(std::string prefix) const {
    return prefix + std::to_string(value);
}
LargeResult Counter::large() const { return ABIBridgeFixture::large(value); }
double Counter::many(int a, int b, int c, int d, int e, int f,
                     int g, int h, int i, int j, double scale, const int& extra) const {
    return (value + a + b + c + d + e + f + g + h + i + j + extra) * scale;
}
}

extern "C" int ABIBridgeFixtureCAdd(int left, int right) { return left + right; }

static void (*unloadCallback)() = nullptr;
extern "C" void ABIBridgeFixtureSetUnloadCallback(void (*callback)()) {
    unloadCallback = callback;
}
__attribute__((destructor)) static void onUnload() {
    if (unloadCallback) unloadCallback();
}
