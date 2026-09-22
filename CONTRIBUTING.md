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
  -scheme ABIBridge-Package \
  -destination 'platform=macOS,arch=arm64'
```

The symbol tests compile temporary C++ libraries with the installed Xcode toolchain. They test real symbol lookup, image retention, and unload/reload behavior.

Build for another Apple platform by changing the generic destination:

```sh
xcodebuild build \
  -scheme ABIBridge-Package \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

For watchOS, add `WATCHOS_DEPLOYMENT_TARGET=11.4` so dependencies also build within the supported deployment range. CI uses Xcode 26.6 on `macos-26` for macOS tests and iOS, visionOS, watchOS, and tvOS builds.

## Documentation

Describe public API contracts in DocC comments. Put guides in the DocC catalog and keep the README at installation and quick-start level. Write prose without manual line wrapping.

Build documentation locally:

```sh
xcodebuild docbuild \
  -scheme ABIBridge \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/ABIBridge-Documentation
```

## Pull requests

Keep each pull request independently buildable and link its issue. Include the behavior changed, relevant validation, and any unverified runtime behavior.
