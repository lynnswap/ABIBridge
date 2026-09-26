#import "HookFixture.h"
#include <stdatomic.h>
static atomic_long results;
@implementation ABINativeHookResult
+ (id)allocWithZone:(struct _NSZone *)zone { atomic_fetch_add(&results, 1); return [super allocWithZone:zone]; }
+ (NSInteger)liveObjects { return atomic_load(&results); }
- (void)dealloc { atomic_fetch_sub(&results, 1); }
@end
@implementation ABINativeHookFixture
- (instancetype)initWithSeed:(int32_t)seed {
    if (seed < 0) return nil;
    if ((self = [super init])) _seed = seed;
    return self;
}
- (int32_t)add:(int32_t)a to:(int32_t)b { _calls++; return a + b; }
- (ABIHookPair)shift:(ABIHookPair)value { return (ABIHookPair){value.x + 1, value.y + 2}; }
- (ABINativeHookResult *)copyObject { return [ABINativeHookResult new]; }
- (int32_t (^)(int32_t))block { return ^(int32_t value) { return value + 1; }; }
@end
Class ABIHookFixtureClass(void) { return ABINativeHookFixture.class; }
void *ABIHookFixtureCreate(int32_t seed) { return (void *)CFBridgingRetain([[ABINativeHookFixture alloc] initWithSeed:seed]); }
void ABIHookFixtureRelease(void *object) { if (object) CFRelease(object); }
int32_t ABIHookFixtureAdd(void *object, int32_t a, int32_t b) { return [(__bridge ABINativeHookFixture *)object add:a to:b]; }
int32_t ABIHookFixtureSeed(void *object) { return [(__bridge ABINativeHookFixture *)object seed]; }
void ABIHookFixtureSetSeed(void *object, int32_t seed) { [(__bridge ABINativeHookFixture *)object setSeed:seed]; }
int32_t ABIHookFixtureCalls(void *object) { return [(__bridge ABINativeHookFixture *)object calls]; }

#include <assert.h>
typedef struct { void *context; void (*event)(void *, int); void (*release)(void *); } MixedContext;
static void mixedRelease(void *value) {
    MixedContext *context = value; context->release(context->context); free(context);
}
static void mixedFailure(void *value, const ABIResolutionFailure *failure) {
    (void)failure; MixedContext *context = value; context->event(context->context, 999);
}
static bool mixedMethod(void *value, ABIObjCHookInvocation *call, ABIResolutionFailure **error) {
    MixedContext *context = value;
    context->event(context->context, 20);
    if (!ABIObjCHookProceed(call, NULL, 0, error)) return false;
    int32_t result = 0;
    if (!ABIObjCHookReadResult(call, &result, sizeof(result), error)) return false;
    ++result; context->event(context->context, -20);
    return ABIObjCHookSetResult(call, &result, sizeof(result), error);
}
static bool mixedBefore(void *value, ABIObjCInitializerArguments *arguments, ABIResolutionFailure **error) {
    MixedContext *context = value; context->event(context->context, 30);
    int32_t seed = 0;
    if (!ABIObjCInitializerReadArgument(arguments, 0, &seed, sizeof(seed), error)) return false;
    if (seed >= 0) ++seed;
    return ABIObjCInitializerSetArgument(arguments, 0, &seed, sizeof(seed), error);
}
static bool mixedAfter(void *value, void *initialized, ABIResolutionFailure **error) {
    (void)error; MixedContext *context = value; context->event(context->context, -30);
    if (initialized) ABIHookFixtureSetSeed(initialized, ABIHookFixtureSeed(initialized) + 1);
    return true;
}
static MixedContext *mixedContext(void *value, void (*event)(void *, int), void (*release)(void *)) {
    MixedContext *result = malloc(sizeof(*result)); *result = (MixedContext){value, event, release}; return result;
}
ABIObjCMethodHook *ABIHookFixtureInstallMethod(void *context, void (*event)(void *, int), void (*release)(void *)) {
    ABIObjCHookValueType integer = {"i", sizeof(int32_t), _Alignof(int32_t)};
    ABIObjCHookValueType arguments[] = {integer, integer};
    ABIObjCHookSignature signature = {integer, arguments, 2};
    ABIResolutionFailure *error = NULL;
    ABIObjCMethodHook *hook = ABIInstallObjCMethodHook(ABIHookFixtureClass(), "add:to:", &signature,
        (ABIObjCHookOptions){0}, mixedContext(context, event, release), mixedMethod, mixedFailure, mixedRelease, &error);
    assert(hook && !error); return hook;
}
ABIObjCMethodHook *ABIHookFixtureInstallInitializer(void *context, void (*event)(void *, int), void (*release)(void *)) {
    ABIObjCHookValueType integer = {"i", sizeof(int32_t), _Alignof(int32_t)};
    ABIObjCHookSignature signature = {{"@", sizeof(id), _Alignof(id)}, &integer, 1};
    ABIResolutionFailure *error = NULL;
    ABIObjCMethodHook *hook = ABIInstallObjCInitializerHook(ABIHookFixtureClass(), "initWithSeed:", &signature,
        (ABIObjCHookOptions){0}, mixedContext(context, event, release), mixedBefore, mixedAfter, mixedFailure, mixedRelease, &error);
    assert(hook && !error); return hook;
}

ABIHookPair ABIHookFixtureShift(void *object, ABIHookPair value) { return [(__bridge ABINativeHookFixture *)object shift:value]; }
