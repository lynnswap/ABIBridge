#include <ABIBridge/Runtime.h>
#include <string>

struct ABIResolutionFailure {
    int32_t code;
    std::string message;
};

ABIResolutionFailure *ABICreateResolutionFailure(int32_t code, const char *message) {
    return new ABIResolutionFailure{code, message};
}
int32_t ABIResolutionFailureCode(const ABIResolutionFailure *error) { return error->code; }
const char *ABIResolutionFailureMessage(const ABIResolutionFailure *error) { return error->message.c_str(); }
void ABIReleaseResolutionFailure(ABIResolutionFailure *error) { delete error; }
