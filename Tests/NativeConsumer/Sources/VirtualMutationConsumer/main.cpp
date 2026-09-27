#include "../../../ArchitectureValidation/Sources/ArchitectureFixtures/include/ArchitectureFixtures.h"
#include <cassert>
#include <cstdio>
int main() {
    for (uint32_t kind=0; kind<3; ++kind) {
        ABIVirtualMutationProbeResult result{};
        const auto *error=ABIValidateVirtualEntry(kind,&result);
        if (error) std::fprintf(stderr,"%s\n",error);
        assert(!error);
        assert(result.publication.didWrite && result.publication.status==ABIPointerSlotComplete);
        assert(result.restoration.didWrite && result.restoration.status==ABIPointerSlotComplete);
    }
    std::puts("Writable virtual-entry control passed");
}
