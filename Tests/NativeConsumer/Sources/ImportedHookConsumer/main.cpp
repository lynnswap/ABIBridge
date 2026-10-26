#include <ABIBridge/Backend/ImportedHooks.h>
#include <ABIBridge/Backend/ManagedVirtualEntry.h>
#include <ABIBridge/ImportedHooks.hpp>
#include <ABIBridge/NativeInvocation.hpp>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <new>
static int released=0;
static void release(void *) { ++released; }
static void failed(void *,const ABIResolutionFailure *) { assert(false); }
static bool callback(void *,ABIImportedInvocation *call,ABIResolutionFailure **error) {
    ABIResolutionFailure *missing=nullptr;
    assert(!ABIImportedInvocationProceed(call,nullptr,0,&missing));
    assert(missing && ABIResolutionFailureGetCode(missing)==ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(missing);
    if(!ABIImportedInvocationProceedWithOriginalArguments(call, error)) return false;
    int32_t result=0;
    if(!ABIImportedInvocationReadResult(call,&result,sizeof(result),error)) return false;
    ++result;
    return ABIImportedInvocationSetResult(call,&result,sizeof(result),error);
}
static void checkFailedStorageCleanup(void *image, const ABIValueType *result) {
    struct Cleanup {
        int32_t (*call)(int32_t,int32_t);
        int32_t observed = 0;
    } cleanup{reinterpret_cast<int32_t(*)(int32_t,int32_t)>(dlsym(image,"ABIImportedCall"))};
    assert(cleanup.call);
    ABIResolutionFailure *error=nullptr;
    auto *receiver=ABICreateScalarType(ABIValuePointer,&error); assert(receiver && !error);
    const ABIValueType *parameters[]{receiver};
    uintptr_t empty=0;
    ABIManagedVirtualEntry entry{&empty,1,0,ABIAuthenticationUnsigned,0,false};
    auto *hook=ABICreateManagedVirtualHook(entry,&cleanup,[](void *context) {
        auto& cleanup=*static_cast<Cleanup*>(context);
        cleanup.observed=cleanup.call(20,21);
    },result,parameters,1,nullptr,callback,failed,[](void*){});
    assert(hook && ABIImportedHookGetFailure(hook)
        && ABIResolutionFailureGetCode(ABIImportedHookGetFailure(hook))==ABIFailureInvalidAddress);
    assert(cleanup.observed==42);
    ABIReleaseImportedHook(hook);
    ABIReleaseValueType(receiver);
}
static int allocationCallbacks = 0;
static bool allocatingRecursively = false;
// Keep this import even in Release: eliding a new/delete pair would miss the
// executable's slot also used by the statically linked dispatcher.
__attribute__((noinline, optnone)) static void *allocate(size_t size) { return ::operator new(size); }
static void checkSelfImportedAllocation() {
    char executable[PATH_MAX]; uint32_t capacity = sizeof(executable);
    assert(_NSGetExecutablePath(executable, &capacity) == 0);
    abi_bridge::runtime runtime;
    auto report=[](const abi_bridge::resolution_error&) noexcept { assert(false); };
    auto hook = abi_bridge::hook_imported_function<void*(size_t)>(runtime,
        {"operator new(unsigned long)", abi_bridge::language::cxx},
        abi_bridge::image_selector::path(executable),
        [](auto& next, size_t size) {
            ++allocationCallbacks;
            if (!allocatingRecursively) {
                allocatingRecursively = true;
                ::operator delete(allocate(8));
                allocatingRecursively = false;
            }
            return next.proceed(size);
        }, report);
    allocationCallbacks = 0;
    void *value = allocate(16);
    assert(value && allocationCallbacks == 2);
    ::operator delete(value);
    hook.invalidate();
    allocationCallbacks = 0;
    value = allocate(16);
    assert(value && allocationCallbacks == 0);
    ::operator delete(value);
}
static int copyCallbacks = 0;
static bool copyingRecursively = false;
__attribute__((noinline, optnone)) static void *copyMemory(void *destination, const void *source, size_t size) {
    return std::memcpy(destination, source, size);
}
static void checkSelfImportedCopy() {
    char executable[PATH_MAX]; uint32_t capacity = sizeof(executable);
    assert(_NSGetExecutablePath(executable, &capacity) == 0);
    abi_bridge::runtime runtime;
    auto report=[](const abi_bridge::resolution_error&) noexcept { assert(false); };
    auto hook = abi_bridge::hook_imported_function<void*(void*,const void*,size_t)>(runtime,
        {"memcpy", abi_bridge::language::c}, abi_bridge::image_selector::path(executable),
        [](auto& next, void *destination, const void *source, size_t size) {
            ++copyCallbacks;
            if (!copyingRecursively) {
                copyingRecursively = true;
                char nested;
                copyMemory(&nested, source, 1);
                copyingRecursively = false;
                assert(nested == *static_cast<const char*>(source));
            }
            return next.proceed(destination, source, size);
        }, report);
    char source[]{1,2,3}, destination[3]{};
    copyCallbacks = 0;
    assert(copyMemory(destination, source, sizeof(source)) == destination);
    assert(copyCallbacks == 2 && destination[0] == 1 && destination[2] == 3);
    hook.invalidate();
    copyCallbacks = 0;
    assert(copyMemory(destination, source, sizeof(source)) == destination);
    assert(copyCallbacks == 0);
}
// No other automatic resolver runs in this process, so final-release checks
// establish ownership instead of racing another suite's valid image leases.
static void checkSelectionLifetime(const char *path) {
    abi_bridge::runtime runtime;
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
        ABISymbolRuntimeRemoveCachedResults(runtime.native_handle());
        dlclose(loader);
        auto *retained=ABIAcquireImageLease(slot.generation); assert(retained);
        ABIReleaseImageLease(retained);
        assert(*reinterpret_cast<const uintptr_t*>(slot.slot)!=0);
        ABIReleaseImportSelection(selection);
        auto *remaining=ABIAcquireImageLease(slot.generation);
        if(remaining) ABIReleaseImageLease(remaining);
        assert(!remaining);
        previous=slot.generation;
    }
}
int main(int argc,char **argv) {
    assert(argc==2); checkSelectionLifetime(argv[1]); void *image=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); assert(image);
    abi_bridge::runtime runtime;
    auto scope=abi_bridge::image_selector::path(argv[1]);
    auto query=abi_bridge::declaration{"ABIImportedAdd",abi_bridge::language::c};
    abi_bridge::function<int32_t(int32_t,int32_t)> call(runtime.resolve({"ABIImportedCall",abi_bridge::language::c},scope));
    ABIResolutionFailure *error=nullptr;
    auto *integer=ABICreateScalarType(ABIValueInt32,&error); assert(integer && !error);
    const ABIValueType *parameters[]{integer,integer};
    const ABIDeclaration cquery{"ABIImportedAdd",ABILanguageC,ABISymbolFunction,ABINameSource};
    auto *c=ABIInstallImportedFunctionHook(runtime.native_handle(),&cquery,scope.native_selector(),nullptr,
        integer,parameters,2,nullptr,callback,failed,release);
    assert(c && !ABIImportedHookGetFailure(c));
    auto report=[](const abi_bridge::resolution_error&) noexcept { assert(false); };
    auto cpp=abi_bridge::hook_imported_function<int32_t(int32_t,int32_t)>(runtime,query,scope,
        [](auto& next,int32_t a,int32_t b) { return next.proceed(a*2,b); },report);
    assert(call.unsafe_invoke(20,1)==42);
    assert(cpp.slot(0).status == abi_bridge::imported_hook_status::active && !cpp.slot(0).mutation.didWrite);
    try { (void)cpp.slot(cpp.size()); assert(false); } catch (const std::out_of_range&) {}
    auto copy=cpp; cpp.invalidate(); assert(copy.slot(0).status==abi_bridge::imported_hook_status::inactive);
    assert(call.unsafe_invoke(20,21)==42);
    checkFailedStorageCleanup(image,integer);
    ABIReleaseValueType(integer);
    ABIInvalidateImportedHook(c); assert(released==1);
    ABIReleaseImportedHook(c); assert(released==1 && call.unsafe_invoke(20,22)==42);
    abi_bridge::function<void(int32_t*,int32_t)> write(runtime.resolve({"ABIImportedWrite",abi_bridge::language::c},scope));
    auto setter=abi_bridge::hook_imported_function<void(int32_t*,int32_t)>(runtime,{"ABIImportedSet",abi_bridge::language::c},scope,
        [](auto& next,int32_t *output,int32_t value){ next.proceed(output,value+1); },report);
    int32_t value=0; write.unsafe_invoke(&value,41); assert(value==42); setter.invalidate();
    write.unsafe_invoke(&value,7); assert(value==7);
    std::optional<abi_bridge::resolution_error> savedFailure;
    try {
        auto bad=abi_bridge::hook_imported_function<int32_t()>(runtime,{"ABIImportedAbsent",abi_bridge::language::c},scope,
            [](auto&){ return 0; },report);
        assert(false);
    } catch(const abi_bridge::imported_hook_installation_error& e) {
        assert(e.registration().size()==0 && !e.failed_index());
        savedFailure = e.cause();
    }
    assert(savedFailure && savedFailure->code() == ABIFailureDeclarationNotFound);
    dlclose(image);
    checkSelfImportedAllocation();
    checkSelfImportedCopy();
    std::puts("Imported C/C++ hook consumer passed");
}
