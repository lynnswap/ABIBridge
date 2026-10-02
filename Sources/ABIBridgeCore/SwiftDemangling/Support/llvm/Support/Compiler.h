#pragma once

#define LLVM_ATTRIBUTE_USED __attribute__((used))
#define LLVM_BUILTIN_UNREACHABLE __builtin_unreachable()
#define LLVM_FALLTHROUGH [[fallthrough]]
#define LLVM_PACKED_START _Pragma("pack(push, 1)")
#define LLVM_PACKED_END _Pragma("pack(pop)")
