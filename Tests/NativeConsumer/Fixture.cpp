#include <string>

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
struct LargeResult { long words[8]; };
LargeResult large(long value) {
    return {{value, value + 1, value + 2, value + 3, value + 4, value + 5, value + 6, value + 7}};
}
int counter = 42;
}

extern "C" int ABIBridgeFixtureCAdd(int left, int right) { return left + right; }

static void (*unloadCallback)() = nullptr;
extern "C" void ABIBridgeFixtureSetUnloadCallback(void (*callback)()) {
    unloadCallback = callback;
}
__attribute__((destructor)) static void onUnload() {
    if (unloadCallback) unloadCallback();
}
