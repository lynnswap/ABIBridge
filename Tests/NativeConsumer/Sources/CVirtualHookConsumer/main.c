#include <ABIBridge/VirtualHooks.h>
#include <assert.h>
#include <limits.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { void *first, *second; } Context;
static int released, storage_released, expected_released;
static void release_storage(void *context) { assert(released==expected_released); ++storage_released; free(context); }
static bool callback(void *context,ABIVirtualInvocation *call,ABIResolutionFailure **error) {
    Context *state=context;
    void *receiver=ABIVirtualInvocationReceiver(call,error);
    assert(receiver==state->first || receiver==state->second);
    int value=0;
    if(!ABIVirtualReadArgument(call,0,&value,sizeof(value),error)) return false;
    ++value; void *arguments[]={&value};
    ABIResolutionFailure *oversized=NULL;
    assert(!ABIVirtualProceed(call,arguments,UINT_MAX,&oversized));
    assert(oversized && ABIResolutionFailureCode(oversized)==ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(oversized);
    if(!ABIVirtualProceed(call,arguments,1,error)) return false;
    int result=0;
    if(!ABIVirtualCopyResult(call,&result,sizeof(result),error)) return false;
    result+=10;
    return ABIVirtualSetResult(call,&result,sizeof(result),error);
}
static void failure(void *context,const ABIResolutionFailure *error) { (void)context; (void)error; assert(false); }
static void release(void *context) { ++released; free(context); }
int main(int argc,char **argv) {
    assert(argc==2);
    void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); assert(library);
    void *(*object)(int)=dlsym(library,"ABIVirtualObject");
    const void *(*table)(void)=dlsym(library,"ABIVirtualTable");
    int (*invoke)(int,int)=dlsym(library,"ABIVirtualCall");
    ABISymbolRuntime *runtime=ABICreateSymbolRuntime();
    ABIResolutionFailure *error=NULL;
    ABIVirtualEntry *selected=ABICopyVirtualEntry(runtime,table(),1,"VirtualFixture::Renderer::value(int) const",&error);
    assert(selected && !error);
    ABIValueType *integer=ABICreateScalarType(ABIValueInt32,&error); assert(integer && !error);
    const ABIValueType *parameters[]={integer};
    Context *context=malloc(sizeof(Context)); assert(context);
    context->first=object(0); context->second=object(1);
    ABIVirtualEntryInfo info=ABIVirtualEntryGet(selected);
    ABIVirtualHook *hook=ABIInstallSharedVirtualHook(info,NULL,NULL,
        integer,parameters,1,context,callback,failure,release);
    assert(hook && !ABIVirtualHookFailure(hook));
    ABIReleaseVirtualEntry(selected); ABIReleaseSymbolRuntime(runtime); ABIReleaseValueType(integer);
    assert(invoke(0,2)==53 && invoke(1,2)==103);
    assert(ABIVirtualHookStatus(hook)==ABIVirtualActive && ABIVirtualHookMutation(hook).didWrite);
    ABIInvalidateVirtualHook(hook);
    assert(released==1 && invoke(0,2)==42);
    ABIReleaseVirtualHook(hook); assert(released==1);
    ABIReleaseVirtualHook(NULL);
    integer=ABICreateScalarType(ABIValueInt32,&error); assert(integer && !error);
    for(int inner=0; inner<4; ++inner) {
        const ABIValueType *invalid[]={NULL};
        expected_released=released+1;
        ABIVirtualHook *bad=ABIInstallSharedVirtualHook(info,malloc(1),release_storage,
            integer,inner ? invalid : NULL,inner==2 ? UINT_MAX : inner==3 ? SIZE_MAX : 1,
            malloc(1),callback,failure,release);
        assert(bad && ABIVirtualHookFailure(bad));
        assert(released==expected_released && storage_released==inner+1);
        ABIReleaseVirtualHook(bad);
        assert(released==expected_released && invoke(0,2)==42);
    }
    ABIReleaseValueType(integer);
    assert(dlclose(library)==0 && invoke(1,2)==92);
    puts("C virtual hook consumer passed");
}
