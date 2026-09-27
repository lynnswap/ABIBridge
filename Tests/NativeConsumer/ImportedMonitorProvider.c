static void (*initializer)(void *);
static void *initializerContext;
void ABISetImportedMonitorInitializer(void (*value)(void *), void *context) {
    initializer = value;
    initializerContext = context;
}
void ABIRunImportedMonitorInitializer(void) { if (initializer) initializer(initializerContext); }
