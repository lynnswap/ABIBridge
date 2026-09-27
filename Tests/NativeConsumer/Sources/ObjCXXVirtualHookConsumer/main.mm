#import <Foundation/Foundation.h>
#include <ABIBridge/VirtualHooks.hpp>
#include "../../VirtualHookFixture.hpp"
#include <cassert>
#include <dlfcn.h>
#include <cstdio>

int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2);
    auto *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); assert(library);
    auto object=reinterpret_cast<void*(*)(int)>(dlsym(library,"ABIVirtualObject"));
    auto invoke=reinterpret_cast<int(*)(int,int)>(dlsym(library,"ABIVirtualCall"));
    auto runtime=abi_bridge::Runtime::current();
    auto table=abi_bridge::virtual_table::from(*static_cast<VirtualFixture::Renderer*>(object(0)),1);
    auto entry=table.entry(runtime,"VirtualFixture::Renderer::value(int) const");
    __weak NSObject *weak;
    auto hook=[&] {
        NSObject *owner=[NSObject new]; weak=owner;
        return entry.hook_shared_calls<int(int)>([owner](auto& call,int value) {
            assert(owner); return call.proceed(value)+10;
        },[](const auto&) noexcept { assert(false); });
    }();
    assert(weak && invoke(0,2)==52 && invoke(1,2)==102);
    hook.invalidate();
    assert(!weak && invoke(0,2)==42);
    assert(dlclose(library)==0);
    puts("Objective-C++ virtual hook consumer passed");
} }
