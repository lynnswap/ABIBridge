extern "C" void ABIBridgeTestConstructorEntered(const void *initializer);

__attribute__((constructor)) static void onLoad() {
    ABIBridgeTestConstructorEntered(reinterpret_cast<const void *>(&onLoad));
}

namespace ABIBridgeReadinessFixture {
int shared() { return 73; }
int pendingOnly() { return 29; }
}
