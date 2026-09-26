#include <ABIBridge/ObjectiveCHooks.h>
#include <HookFixture.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static int disposed, failures;
static void dispose(void *context) { ++disposed; free(context); }
static void failure(void *context, const ABIResolutionFailure *error) { (void)context; assert(error); ++failures; }
static bool add(void *context, ABIObjCHookInvocation *call, ABIResolutionFailure **error) {
    int32_t a = 0, b = 0, result = 0;
    if (!ABIObjCHookReadArgument(call, 0, &a, sizeof(a), error) || !ABIObjCHookReadArgument(call, 1, &b, sizeof(b), error)) return false;
    if (*(int *)context == 1) {
        result = 99;
        assert(ABIObjCHookSetResult(call, &result, sizeof(result), error));
        *error = ABICreateResolutionFailure(ABIFailureOther, "Before downstream");
        return false;
    }
    const void *arguments[] = {&a, &b};
    if (!ABIObjCHookProceed(call, arguments, 2, error) || !ABIObjCHookReadResult(call, &result, sizeof(result), error)) return false;
    if (*(int *)context == 2) { *error = ABICreateResolutionFailure(ABIFailureOther, "After downstream"); return false; }
    result += 1;
    return ABIObjCHookSetResult(call, &result, sizeof(result), error);
}
static bool before(void *context, ABIObjCInitializerArguments *arguments, ABIResolutionFailure **error) {
    (void)context;
    int32_t seed = 0;
    if (!ABIObjCInitializerReadArgument(arguments, 0, &seed, sizeof(seed), error)) return false;
    if (seed >= 0) ++seed;
    return ABIObjCInitializerSetArgument(arguments, 0, &seed, sizeof(seed), error);
}
static bool after(void *context, void *initialized, ABIResolutionFailure **error) {
    (void)context; (void)error;
    if (initialized) ABIHookFixtureSetSeed(initialized, ABIHookFixtureSeed(initialized) + 40);
    return true;
}
int main(void) {
    ABIObjCHookValueType integer = {"i", sizeof(int32_t), _Alignof(int32_t)};
    ABIObjCHookValueType arguments[] = {integer, integer};
    ABIObjCHookSignature signature = {integer, arguments, 2};
    ABIObjCHookOptions options = {0};
    ABIResolutionFailure *error = NULL;
    void *object = ABIHookFixtureCreate(0);
    for (int mode = 0; mode != 3; ++mode) {
        int *context = malloc(sizeof(int)); *context = mode;
        ABIObjCMethodHook *hook = ABIInstallObjCMethodHook(ABIHookFixtureClass(), "add:to:", &signature,
            options, context, add, failure, dispose, &error);
        assert(hook && !error && ABIObjCMethodHookStatus(hook) == ABIObjCHookActive);
        int32_t calls = ABIHookFixtureCalls(object);
        assert(ABIHookFixtureAdd(object, 20, 21) == (mode ? 41 : 42));
        assert(ABIHookFixtureCalls(object) == calls + 1);
        ABIObjCMethodHook *copy = ABIRetainObjCMethodHook(hook);
        ABIReleaseObjCMethodHook(hook);
        assert(ABIObjCMethodHookStatus(copy) == ABIObjCHookActive);
        ABIInvalidateObjCMethodHook(copy); ABIInvalidateObjCMethodHook(copy);
        assert(ABIObjCMethodHookStatus(copy) == ABIObjCHookInvalidated);
        ABIReleaseObjCMethodHook(copy);
    }
    assert(disposed == 3 && failures == 2);
    int *context = calloc(1, sizeof(int));
    assert(!ABIInstallObjCMethodHook(NULL, "add:to:", &signature, options, context, add, failure, dispose, &error));
    assert(error && disposed == 4); ABIReleaseResolutionFailure(error); error = NULL;
    ABIObjCHookSignature malformed = signature;
    malformed.result.encoding = "ijunk";
    assert(!ABIInstallObjCMethodHook(ABIHookFixtureClass(), "add:to:", &malformed, options,
        calloc(1, sizeof(int)), add, failure, dispose, &error));
    assert(error && disposed == 5); ABIReleaseResolutionFailure(error); error = NULL;
    malformed.result.encoding = "c";
    assert(!ABIInstallObjCMethodHook(ABIHookFixtureClass(), "add:to:", &malformed, options,
        calloc(1, sizeof(int)), add, failure, dispose, &error));
    assert(error && disposed == 6); ABIReleaseResolutionFailure(error); error = NULL;
    ABIObjCHookSignature initializer = {{"@", sizeof(void *), _Alignof(void *)}, &integer, 1};
    ABIObjCMethodHook *hook = ABIInstallObjCInitializerHook(ABIHookFixtureClass(), "initWithSeed:", &initializer,
        options, NULL, before, after, failure, dispose, &error);
    assert(hook && !error);
    void *initialized = ABIHookFixtureCreate(1);
    assert(ABIHookFixtureSeed(initialized) == 42);
    assert(ABIHookFixtureCreate(-1) == NULL);
    ABIHookFixtureRelease(initialized);
    ABIReleaseObjCMethodHook(hook);
    assert(disposed == 7);
    ABIInvalidateObjCMethodHook(NULL); ABIReleaseObjCMethodHook(NULL);
    ABIHookFixtureRelease(object);
    puts("C hook consumer passed");
}
