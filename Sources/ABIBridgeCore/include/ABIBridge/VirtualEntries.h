#ifndef ABIBRIDGE_VIRTUAL_ENTRIES_H
#define ABIBRIDGE_VIRTUAL_ENTRIES_H
#include <ABIBridge/NativeDispatch.h>
#ifdef __cplusplus
extern "C" {
#endif

/// An immutable named entry retaining the loaded image containing the table.
typedef struct ABIVirtualEntry ABIVirtualEntry;
/// Copied slot and authentication metadata. The table's first function entry is
/// the address point; RTTI and offset-to-top headers are outside its bounds.
typedef struct {
    const void *addressPoint;
    size_t entryCount;
    size_t index;
    int32_t key;
    uintptr_t discriminator;
    bool addressDiversity;
} ABIVirtualEntryInfo;

/// Selects an absolute entry by a qualified C++ implementation declaration.
/// The caller supplies the actual address point and function-entry count.
/// Original chained fixups establish target and authentication identity, so
/// a replaced live pointer does not change selection. No image is loaded.
/// Missing files/symbol identities and ambiguous aliases are reported instead
/// of guessing from a current target address. Unsupported tables need adapters.
///
/// Keep the runtime and table alive during lookup. Returns an owned entry or
/// null and an owned failure. Success clears *error; an old *error is overwritten,
/// not released. Name is nonnull UTF-8; no mangled spelling is required.
ABIVirtualEntry *ABICopyVirtualEntry(ABISymbolRuntime *runtime,
    const void *addressPoint, size_t entryCount, const char *name,
    ABIResolutionFailure **error);
/// Returns copied metadata for a live nonnull entry.
ABIVirtualEntryInfo ABIVirtualEntryGet(const ABIVirtualEntry *entry);
/// Returns the original symbol (possibly a thunk), borrowed until entry release.
const char *ABIVirtualEntrySymbolName(const ABIVirtualEntry *entry);
/// Releases an owned entry. Null is accepted; do not race final release with reads.
void ABIReleaseVirtualEntry(ABIVirtualEntry *entry);
#ifdef __cplusplus
}
#endif
#endif
