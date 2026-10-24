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
    void *receiver=ABIVirtualInvocationGetReceiver(call,error);
    assert(receiver==state->first || receiver==state->second);
    int value=0;
    if(!ABIVirtualInvocationReadArgument(call,0,&value,sizeof(value),error)) return false;
    ABIResolutionFailure *missing=NULL;
    assert(!ABIVirtualInvocationProceed(call,NULL,0,&missing));
    assert(missing && ABIResolutionFailureGetCode(missing)==ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(missing);
    if(!ABIVirtualInvocationProceedWithOriginalArguments(call,error)) return false;
    int original=0;
    if(!ABIVirtualInvocationReadResult(call,&original,sizeof(original),error)) return false;
    ++value; const void *arguments[]={&value};
    ABIResolutionFailure *oversized=NULL;
    assert(!ABIVirtualInvocationProceed(call,arguments,UINT_MAX,&oversized));
    assert(oversized && ABIResolutionFailureGetCode(oversized)==ABIFailureInvalidRequest);
    ABIReleaseResolutionFailure(oversized);
    if(!ABIVirtualInvocationProceed(call,arguments,1,error)) return false;
    int result=0;
    if(!ABIVirtualInvocationReadResult(call,&result,sizeof(result),error)) return false;
    assert(result==original+1);
    result+=10;
    return ABIVirtualInvocationSetResult(call,&result,sizeof(result),error);
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
    ABIVirtualEntryInfo info=ABIVirtualEntryGetInfo(selected);
    ABIVirtualHook *hook=ABIInstallSharedVirtualHook(info,NULL,NULL,
        integer,parameters,1,context,callback,failure,release);
    assert(hook && !ABIVirtualHookGetFailure(hook));
    ABIReleaseVirtualEntry(selected); ABIReleaseSymbolRuntime(runtime); ABIReleaseValueType(integer);
    assert(invoke(0,2)==53 && invoke(1,2)==103);
    assert(ABIVirtualHookGetStatus(hook)==ABIVirtualActive && ABIVirtualHookGetMutation(hook).didWrite);
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
        assert(bad && ABIVirtualHookGetFailure(bad));
        assert(released==expected_released && storage_released==inner+1);
        ABIReleaseVirtualHook(bad);
        assert(released==expected_released && invoke(0,2)==42);
    }
    ABIReleaseValueType(integer);
    assert(dlclose(library)==0 && invoke(1,2)==92);
    puts("C virtual hook consumer passed");
}
