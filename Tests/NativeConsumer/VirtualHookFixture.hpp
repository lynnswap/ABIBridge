#pragma once
namespace VirtualFixture {
struct Request { int value, observed; };
struct Renderer {
    int seed;
    explicit Renderer(int value):seed(value) {}
    virtual int value(int) const;
    virtual int edit(Request *) const;
};
}
