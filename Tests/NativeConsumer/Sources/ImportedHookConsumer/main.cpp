#include <ABIBridge/ImportedHooks.hpp>
#include <ABIBridge/NativeInvocation.hpp>
#include <cassert>
#include <cstdio>
#include <dlfcn.h>
static int released=0;
static void release(void *) { ++released; }
static void failed(void *,const ABIResolutionFailure *) { assert(false); }
static bool callback(void *,ABIImportedInvocation *call,ABIResolutionFailure **error) {
    if(!ABIImportedProceed(call,nullptr,0,error)) return false;
    int32_t result=0;
    if(!ABIImportedCopyResult(call,&result,sizeof(result),error)) return false;
    ++result;
    return ABIImportedSetResult(call,&result,sizeof(result),error);
}
// No other automatic resolver runs in this process, so final-release checks
// establish ownership instead of racing another suite's valid image leases.
static void checkSelectionLifetime(const char *path) {
    abi_bridge::Runtime runtime;
    auto scope=abi_bridge::image_selector::path(path);
    const ABIDeclaration query{"ABIImportedAdd",ABILanguageC,ABISymbolFunction,ABINameSource};
    uint64_t previous=0;
    for(int pass=0;pass<2;++pass) {
        void *loader=dlopen(path,RTLD_NOW|RTLD_LOCAL); assert(loader);
        ABIResolutionFailure *error=nullptr;
        auto *selection=ABICopyImportSelection(runtime.native_handle(),&query,scope.native_selector(),nullptr,&error);
        assert(selection && !error && ABIImportSelectionCount(selection)==1);
        const auto slot=ABIImportSelectionGet(selection,0);
        assert(slot.generation!=previous && slot.slot);
        ABIRuntimeRemoveCachedResults(runtime.native_handle());
        dlclose(loader);
        auto *retained=ABIRetainLoadedImage(slot.generation); assert(retained);
        ABIReleaseImage(retained);
        assert(*reinterpret_cast<const uintptr_t*>(slot.slot)!=0);
        ABIReleaseImportSelection(selection);
        auto *remaining=ABIRetainLoadedImage(slot.generation);
        if(remaining) ABIReleaseImage(remaining);
        assert(!remaining);
        previous=slot.generation;
    }
}
int main(int argc,char **argv) {
    assert(argc==2); checkSelectionLifetime(argv[1]); void *image=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); assert(image);
    abi_bridge::Runtime runtime;
    auto scope=abi_bridge::image_selector::path(argv[1]);
    auto query=abi_bridge::declaration{"ABIImportedAdd",abi_bridge::language::c};
    abi_bridge::function<int32_t(int32_t,int32_t)> call(runtime.resolve({"ABIImportedCall",abi_bridge::language::c},scope));
    ABIResolutionFailure *error=nullptr;
    auto *integer=ABICreateScalarType(ABIValueInt32,&error); assert(integer && !error);
    const ABIValueType *parameters[]{integer,integer};
    const ABIDeclaration cquery{"ABIImportedAdd",ABILanguageC,ABISymbolFunction,ABINameSource};
    auto *c=ABIInstallImportedFunctionHook(runtime.native_handle(),&cquery,scope.native_selector(),nullptr,
        integer,parameters,2,nullptr,callback,failed,release);
    assert(c && !ABIImportedHookFailure(c)); ABIReleaseValueType(integer);
    auto report=[](const abi_bridge::resolution_error&) noexcept { assert(false); };
    auto cpp=abi_bridge::hook_imported_function<int32_t(int32_t,int32_t)>(runtime,query,scope,
        [](auto& next,int32_t a,int32_t b) { return next.proceed(a*2,b); },report);
    assert(call.unsafe_invoke(20,1)==42);
    auto copy=cpp; cpp.invalidate(); assert(copy.status(0)==ABIImportedInactive);
    assert(call.unsafe_invoke(20,21)==42);
    ABIInvalidateImportedHook(c); assert(released==1);
    ABIReleaseImportedHook(c); assert(released==1 && call.unsafe_invoke(20,22)==42);
    abi_bridge::function<void(int32_t*,int32_t)> write(runtime.resolve({"ABIImportedWrite",abi_bridge::language::c},scope));
    auto setter=abi_bridge::hook_imported_function<void(int32_t*,int32_t)>(runtime,{"ABIImportedSet",abi_bridge::language::c},scope,
        [](auto& next,int32_t *output,int32_t value){ next.proceed(output,value+1); },report);
    int32_t value=0; write.unsafe_invoke(&value,41); assert(value==42); setter.invalidate();
    write.unsafe_invoke(&value,7); assert(value==7);
    try {
        auto bad=abi_bridge::hook_imported_function<int32_t()>(runtime,{"ABIImportedAbsent",abi_bridge::language::c},scope,
            [](auto&){ return 0; },report);
        assert(false);
    } catch(const abi_bridge::imported_hook_installation_error& e) {
        assert(e.registration().size()==0 && e.failed_index()==SIZE_MAX);
    }
    dlclose(image);
    std::puts("Imported C/C++ hook consumer passed");
}
