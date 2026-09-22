#pragma once
#include <string>

namespace ABIBridgeFixture {
struct LargeResult { long words[8]; };

struct Counter {
    int value;
    int add(int delta);
    int current() const;
    int& reference();
    std::string describe(std::string prefix) const;
    LargeResult large() const;
    double many(int a, int b, int c, int d, int e, int f,
                int g, int h, int i, int j, double scale, const int& extra) const;
};

struct VirtualCounter {
    int value;
    explicit VirtualCounter(int value) : value(value) {}
    virtual int current() const;
};

struct Prefix { long padding[4]; };
struct Combined : Prefix, Counter {};
}
