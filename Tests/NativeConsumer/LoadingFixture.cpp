extern "C" void ABIBridgeLoadingDidInitialize();
extern "C" void ABIBridgeLoadingWillInitialize();
static int initialized = 0;
__attribute__((constructor)) static void initialize() {
    ABIBridgeLoadingWillInitialize();
    initialized = 42;
    ABIBridgeLoadingDidInitialize();
}
extern "C" int ABIBridgeLoadedValue() { return initialized; }
namespace ABIBridgeLoading {
__attribute__((used, noinline, visibility("hidden"))) int hiddenValue() { return initialized; }
}
