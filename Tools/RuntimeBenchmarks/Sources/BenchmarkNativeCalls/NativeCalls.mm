#include "BenchmarkNativeCalls.h"
#include <ABIBridge/ABIBridge.hpp>
#include <ABIBridge/ObjectiveCInvocation.hpp>
#import <BenchmarkNativeProvider.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <iostream>
template <class F> void measure(const char *label, F body) {
  constexpr int n = 50000;
  long sum = 0;
  for (int i = 0; i < 2000; i++)
    sum += body(i & 1023);
  std::array<double, 5> times;
  for (auto &time : times) {
    sum = 0;
    auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < n; i++)
      sum += body(i & 1023);
    time = std::chrono::duration<double, std::micro>(
               std::chrono::steady_clock::now() - start)
               .count() /
           n;
  }
  const long remainder = n % 1024;
  const long expected =
      (n / 1024) * 523776L + remainder * (remainder - 1) / 2 + 7L * n;
  if (sum != expected) {
    std::cerr << "Incorrect result in " << label << std::endl;
    std::abort();
  }
  std::sort(times.begin(), times.end());
  std::cout << label << ": " << times[2] << " us/call checksum=" << sum
            << std::endl;
}
extern "C" void ABIPerfRunNative() {
  @autoreleasepool {
    auto runtime = abi_bridge::InvocationRuntime::current();
    auto c = runtime.c_function<int32_t(int32_t, int32_t)>("ABIPerfCAdd");
    auto cpp = runtime.cxx_function<int(int, int)>(
        abi_bridge::declaration("ABIPerf::add(int, int)"));
    measure("C++ direct", [](int x) { return ABIPerf::add(x, 7); });
    measure("C direct", [](int x) { return ABIPerfCAdd(x, 7); });
    measure("C++ prepared native handle",
            [&](int x) { return cpp.unsafe_invoke(x, 7); });
    measure("C prepared native handle",
            [&](int x) { return c.unsafe_invoke(x, 7); });
    ABIPerfReceiver *receiver = [ABIPerfReceiver new];
    auto bound =
        abi_bridge::bound_objc_implementation<int64_t(int64_t, int64_t)>(
            receiver, "add:right:");
    measure("ObjC direct", [&](int x) { return [receiver add:x right:7]; });
    measure("ObjC++ prepared captured IMP",
            [&](int x) { return bound.unsafe_invoke(x, 7); });
  }
}
