#pragma once
namespace VirtualFixture {
struct Renderer {
    int seed;
    explicit Renderer(int value):seed(value) {}
    virtual int value(int) const;
};
}
