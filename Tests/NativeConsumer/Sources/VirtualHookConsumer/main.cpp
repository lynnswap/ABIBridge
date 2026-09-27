#include <ABIBridge/VirtualHooks.hpp>
#include "../../VirtualHookFixture.hpp"
#include <cassert>
#include <dlfcn.h>
#include <cstdio>

int main(int argc,char **argv) {
    assert(argc==2);
    auto *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); assert(library);
    auto object=reinterpret_cast<void*(*)(int)>(dlsym(library,"ABIVirtualObject"));
    auto invoke=reinterpret_cast<int(*)(int,int)>(dlsym(library,"ABIVirtualCall"));
    auto runtime=abi_bridge::Runtime::current();
    auto table=abi_bridge::virtual_table::from(*static_cast<VirtualFixture::Renderer*>(object(0)),2);
    auto entry=table.entry(runtime,"VirtualFixture::Renderer::value(int) const");
    auto copy=entry; copy=entry;
    auto hook=entry.hook_shared_calls<int(int)>([object](auto& call,int value) {
        assert(call.receiver()==object(0) || call.receiver()==object(1));
        return call.proceed(value+1)+10;
    },[](const auto&) noexcept { assert(false); });
    assert(invoke(0,2)==53 && invoke(1,2)==103);
    const auto info=entry.native_info();
    auto explicitEntry=table.entry(0,info.key,info.discriminator,info.addressDiversity);
    auto second=explicitEntry.hook_shared_calls<int(int)>([](auto& call,int value) { return call.proceed(value)*2; },[](const auto&) noexcept { assert(false); });
    assert(invoke(0,2)==106 && !second.slot()->mutation.didWrite);
    hook.invalidate(); assert(invoke(0,2)==84);
    second.invalidate(); assert(invoke(0,2)==42);
    assert(second.slot()->status==ABIVirtualInactive);
    int errors=0;
    auto failed=entry.hook_shared_calls<int(int)>([](auto&,int)->int { throw std::runtime_error("callback error"); },[&](const auto& error) noexcept {
        ++errors; assert(std::string(error.what())=="callback error");
    });
    assert(invoke(0,2)==42 && errors==1); failed.invalidate();
    auto edit=reinterpret_cast<int(*)(void*)>(dlsym(library,"ABIVirtualEdit"));
    auto editEntry=table.entry(runtime,"VirtualFixture::Renderer::edit(VirtualFixture::Request*) const");
    VirtualFixture::Request request{2,0};
    auto editing=editEntry.hook_shared_calls<int(VirtualFixture::Request*)>([](auto& call,auto *request) {
        request->value=7;
        const auto result=call.proceed(request);
        ++request->observed;
        return result;
    },[](const auto&) noexcept { assert(false); });
    assert(edit(&request)==47 && request.value==7 && request.observed==48);
    editing.invalidate();
    VirtualFixture::Request replacement{11,0};
    auto redirect=editEntry.hook_shared_calls<int(VirtualFixture::Request*)>([&](auto& call,auto*) { return call.proceed(&replacement); },[](const auto&) noexcept { assert(false); });
    request={3,0};
    assert(edit(&request)==51 && replacement.observed==51 && request.value==3 && request.observed==0);
    redirect.invalidate();
    assert(dlclose(library)==0);
    assert(invoke(1,2)==92); // Published entry keeps the fixture image leased.
    puts("C++ virtual hook consumer passed");
}
