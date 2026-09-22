# Contributing

Use Xcode with Swift 6.3 or later. Keep changes on a topic branch and open a pull request against `main`.

## Validation

Check the package manifest and whitespace:

```sh
swift package dump-package
git diff --check
```

Run tests on macOS:

```sh
xcodebuild test \
  -scheme ABIBridge \
  -destination 'platform=macOS,arch=arm64'
```

Verify the native bridge in an optimized build as well:

```sh
xcodebuild test \
  -configuration Release \
  -scheme ABIBridge \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ABIBridgeTests/NativeRuntimeTests
```

This checks that the C entry points remain externally linkable after Xcode combines the optimized package objects. CI runs the same check.

The symbol tests compile temporary C++ libraries with the installed Xcode toolchain. They test real symbol lookup, image retention, and unload/reload behavior. Objective-C invocation tests use Swift and Objective-C fixtures to check typed arguments, forwarding, caller isolation, returned-object ownership, initializer behavior, and signature failures. Typed C/C++ invocation tests additionally cover standard C value layouts, twelve mixed arguments, optional pointers, concurrent handle reuse, and invocation after the original loader reference is released. Native value tests cover custom wrappers, runtime signatures, borrowed/adopted ownership, failed conversions, field views, unaligned reads, and invalid layouts.

Run the native backend fixtures to verify linking and ABI behavior through the `ABIBridge` product:

```sh
bash scripts/test-native-consumer.sh
```

This fixture checks C/C++ calls, instance methods, receiver ownership, multiple-inheritance subobjects, reference arguments, non-trivial and indirect results, register/stack argument passing, concurrent resolution, and image retention after the original loader reference is released. Objective-C++ consumers additionally check selector signatures, ARC and manual-reference-counting lifetimes, initializer ownership, and block arguments/results. The dynamic C consumer checks libffi-backed calls with zero and twelve arguments, narrow scalar results, pointers, nested aggregate layouts and returns, retained type descriptions, and concurrent preparation/invocation. A separate Swift consumer links the public product and invokes C/C++ functions after releasing its original loader reference. CI runs these consumers after the macOS package tests.

Build for another Apple platform by changing the generic destination:

```sh
xcodebuild build \
  -scheme ABIBridge \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

For watchOS, add `WATCHOS_DEPLOYMENT_TARGET=11.4` so dependencies also build within the supported deployment range. CI uses Xcode 26.6 on `macos-26` for macOS tests and iOS, visionOS, watchOS, and tvOS builds.

## Documentation

The supported consumer API is the Swift `ABIBridge` module. `ABIBridgeCore`, `ABIBridgeObjCXX`, and their headers are implementation details used by the backends and fixtures. SwiftPM may make transitive modules importable; that does not make those interfaces supported public API.

Describe public Swift API contracts in DocC comments. Put guides in the DocC catalog and keep the README at installation and quick-start level. Write prose without manual line wrapping.

Build the same static site that is published by CI:

```sh
bash scripts/build-documentation.sh
```

The default output is `.build/documentation`. Optional arguments select the output directory and hosting base path. The script validates ABIBridge's catalog with DocC warnings treated as errors, while dependency documentation warnings remain separate.

Pushes to `main` build and deploy the site to GitHub Pages. Pull requests run the package CI without a documentation job.

## Pull requests

Keep each pull request independently buildable and link its issue. Include the behavior changed, relevant validation, and any unverified runtime behavior.
