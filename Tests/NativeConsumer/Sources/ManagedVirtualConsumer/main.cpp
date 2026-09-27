#include "../../../ArchitectureValidation/Sources/ArchitectureFixtures/include/ArchitectureFixtures.h"
#include <ABIBridge/ManagedVirtualEntry.h>
#include <ABIBridge/Inspection.hpp>
#include <cassert>
#include <cstdio>
#include <dlfcn.h>

static bool increment(void *context, ABIImportedInvocation *call, ABIResolutionFailure **error) {
    int32_t *receiver=nullptr; int32_t value=0;
    if (!ABIImportedReadArgument(call,0,&receiver,sizeof(receiver),error)
        || !ABIImportedReadArgument(call,1,&value,sizeof(value),error)) return false;
    value+=*static_cast<int*>(context);
    void *arguments[]={&receiver,&value};
    return ABIImportedProceed(call,arguments,2,error) && ABIImportedSetResult(call,nullptr,0,error);
}
static void failed(void *,const ABIResolutionFailure *) { assert(false && "Unexpected overlap callback failure"); }
static void release(void *context) { delete static_cast<int*>(context); }

static void overlappingImports(const char *path) {
    auto *library=dlopen(path,RTLD_NOW|RTLD_LOCAL); assert(library);
    auto call=reinterpret_cast<void(*)(int32_t*,int32_t)>(dlsym(library,"ABIImportedWrite")); assert(call);
    abi_bridge::Runtime runtime;
    ABIImageSelector scope{ABIImagePath,path};
    ABIDeclaration declaration{"ABIImportedSet",ABILanguageC,ABISymbolFunction,ABINameSource};
    ABIResolutionFailure *error=nullptr;
    auto *pointer=ABICreateScalarType(ABIValuePointer,&error); assert(pointer && !error);
    auto *integer=ABICreateScalarType(ABIValueInt32,&error); assert(integer && !error);
    auto *output=ABICreateScalarType(ABIValueVoid,&error); assert(output && !error);
    const ABIValueType *parameters[]={pointer,integer};
    auto *selection=ABICopyImportSelection(runtime.native_handle(),&declaration,scope,nullptr,&error);
    assert(selection && !error && ABIImportSelectionCount(selection)==1);
    const auto slot=ABIImportSelectionGet(selection,0);
    ABIReleaseImportSelection(selection);
    auto *imported=ABIInstallImportedFunctionHook(runtime.native_handle(),&declaration,scope,nullptr,output,parameters,2,
        new int(1),increment,failed,release);
    assert(imported && !ABIImportedHookFailure(imported));
    ABIManagedVirtualEntry entry{reinterpret_cast<const void*>(slot.slot),1,0,slot.key,slot.discriminator,slot.addressDiversity};
    auto *virtualHook=ABICreateManagedVirtualHook(entry,nullptr,nullptr,output,parameters,2,new int(2),increment,failed,release);
    assert(virtualHook && !ABIImportedHookFailure(virtualHook));
    assert(!ABIImportedHookMutation(virtualHook,0).didWrite);
    int32_t value=0; call(&value,39); assert(value==42);
    ABIInvalidateImportedHook(imported); call(&value,40); assert(value==42);
    ABIInvalidateImportedHook(virtualHook); call(&value,42); assert(value==42);
    ABIReleaseImportedHook(imported); ABIReleaseImportedHook(virtualHook);
    ABIReleaseValueType(output); ABIReleaseValueType(integer); ABIReleaseValueType(pointer);
    dlclose(library);
}
int main(int argc,char **argv) {
    assert(argc==2);
    bool published=false;
    const auto *error=ABIValidateManagedVirtualHooks(true,&published);
    if (error) std::fprintf(stderr,"%s\n",error);
    assert(!error && published);
    overlappingImports(argv[1]);
    std::puts("Managed virtual-entry consumer passed");
}
