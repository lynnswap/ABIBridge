#include "VirtualHookFixture.hpp"
namespace VirtualFixture {
int Renderer::value(int value) const { return seed + value; }
Renderer objects[] = {Renderer(40),Renderer(90)};
__attribute__((noinline)) int invoke(const Renderer *object,int value) { return object->value(value); }
}
extern "C" void *ABIVirtualObject(int index) { return &VirtualFixture::objects[index]; }
extern "C" const void *ABIVirtualTable() { return __builtin_get_vtable_pointer(&VirtualFixture::objects[0]); }
extern "C" int ABIVirtualCall(int index,int value) { return VirtualFixture::invoke(&VirtualFixture::objects[index],value); }
