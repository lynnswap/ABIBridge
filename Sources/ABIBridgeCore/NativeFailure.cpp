#include <ABIBridge/Backend/Runtime.h>
#include <string>

struct ABIResolutionFailure {
    int32_t code;
    std::string message;
};

ABIResolutionFailure *ABICreateResolutionFailure(int32_t code, const char *message) {
    return new ABIResolutionFailure{code, message};
}
int32_t ABIResolutionFailureGetCode(const ABIResolutionFailure *error) { return error->code; }
const char *ABIResolutionFailureGetMessage(const ABIResolutionFailure *error) { return error->message.c_str(); }
void ABIReleaseResolutionFailure(ABIResolutionFailure *error) { delete error; }
