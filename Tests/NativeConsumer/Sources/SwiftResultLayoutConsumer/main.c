// Prints ABIBridge's slots for each Swift tuple result named on the command
// line, one line each, for scripts/check-swift-tuple-result-codegen.py.
// Each character is an element: R and S are resilient 8- and 24-byte values,
// i is Int64, and v is an empty tuple.
#include <ABIBridge/Invocation.h>
#include <ABIBridge/SwiftInvocation.h>
#include <ABIBridgeCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static ABIValueType *element(char kind) {
    ABIResolutionFailure *error = NULL;
    ABIValueType *type = NULL;
    switch (kind) {
    case 'R': type = ABICreateSwiftIndirectStorageType(8, 8, &error); break;
    case 'S': type = ABICreateSwiftIndirectStorageType(24, 8, &error); break;
    case 'i': type = ABICreateScalarType(ABIValueInt64, &error); break;
    case 'v': type = ABICreateScalarType(ABIValueVoid, &error); break;
    default: fprintf(stderr, "Unknown element kind: %c\n", kind); exit(2);
    }
    if (!type) {
        fprintf(stderr, "Element %c: %s\n", kind, ABIResolutionFailureGetMessage(error));
        exit(1);
    }
    return type;
}

int main(int argc, char **argv) {
    for (int argument = 1; argument < argc; ++argument) {
        const char *elements = argv[argument];
        const size_t count = strlen(elements);
        ABIValueType **fields = calloc(count, sizeof(ABIValueType *));
        size_t *offsets = calloc(count, sizeof(size_t));
        size_t size = 0, alignment = 1;
        for (size_t index = 0; index < count; ++index) {
            fields[index] = element(elements[index]);
            const size_t fieldAlignment = ABIValueTypeGetAlignment(fields[index]);
            size = (size + fieldAlignment - 1) / fieldAlignment * fieldAlignment;
            offsets[index] = size;
            size += ABIValueTypeGetSize(fields[index]);
            if (fieldAlignment > alignment) alignment = fieldAlignment;
        }
        ABIResolutionFailure *error = NULL;
        ABIValueType *tuple = ABICreateSwiftTupleStorageType(
            (const ABIValueType *const *)fields, offsets, count, size, alignment, &error);
        if (!tuple) {
            fprintf(stderr, "Tuple %s: %s\n", elements, ABIResolutionFailureGetMessage(error));
            return 1;
        }
        char *description = ABICopySwiftValueLoweringDescription(tuple, true);
        printf("%s\n", description);
        ABIFreeString(description);
        ABIReleaseValueType(tuple);
        for (size_t index = 0; index < count; ++index) ABIReleaseValueType(fields[index]);
        free(fields);
        free(offsets);
    }
    return 0;
}
