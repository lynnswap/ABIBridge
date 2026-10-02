#pragma once

#include "StringRef.h"
#include <optional>

namespace llvm {
template<class Value> class StringSwitch {
    StringRef string;
    std::optional<Value> value;
public:
    StringSwitch(StringRef string) : string(string) {}
    StringSwitch &Case(StringRef key, Value candidate) {
        if (!value && string == key) value = candidate;
        return *this;
    }
    Value Default(Value candidate) const { return value.value_or(candidate); }
};
}
