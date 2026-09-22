extern "C" void ABIBridgeTestConstructorEntered();

__attribute__((constructor)) static void onLoad() {
    ABIBridgeTestConstructorEntered();
}
