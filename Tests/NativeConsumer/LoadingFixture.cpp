extern "C" void ABIBridgeLoadingDidInitialize();
static int initialized = 0;
__attribute__((constructor)) static void initialize() {
    initialized = 42;
    ABIBridgeLoadingDidInitialize();
}
extern "C" int ABIBridgeLoadedValue() { return initialized; }
namespace ABIBridgeLoading {
__attribute__((used, noinline, visibility("hidden"))) int hiddenValue() { return initialized; }
}
