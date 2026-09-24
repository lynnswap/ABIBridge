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

The symbol tests compile temporary C++ libraries with the installed Xcode toolchain. They test real symbol lookup, image retention, and unload/reload behavior. Objective-C invocation tests use Swift and Objective-C fixtures to check typed arguments, forwarding, caller isolation, returned-object ownership, initializer behavior, and signature failures. Typed C/C++ invocation tests additionally cover standard C value layouts, twelve mixed arguments, optional pointers, concurrent handle reuse, and invocation after the original loader reference is released. Swift invocation tests compare normal calls with dynamically resolved calls for mixed register/stack arguments, ownership, integer-field coalescing, four-register results, and indirect results. Guarded argument/result pages verify that coalesced registers do not read or write beyond an odd-sized value's allocation. Native value tests cover custom wrappers, runtime signatures, borrowed/adopted ownership, failed conversions, field views, unaligned reads, and invalid layouts.

Memory tests verify owned copies, region bounds, unaligned reads, zero-length requests, inaccessible source addresses, and readable prefixes before protected pages. The C, C++, and Objective-C++ consumers exercise the shared reader, including owner release and ARC/MRC builds. Runtime evidence is from macOS; other Apple platforms compile in CI.

Pointer discovery tests cover shifted fields, cached-offset revalidation, aliases versus distinct targets, incomplete scans, packed slots, explicit vptr offsets, retained owners, and feeding a selected receiver to existing C++ invocation. Native consumers additionally exercise guarded source slots and PAC-bearing data in plain arm64 builds. Compile the scanner for arm64e as well; this is not a physical-device authenticated-dispatch test.

Run the native backend fixtures to verify linking and ABI behavior through the `ABIBridge` product:

```sh
bash scripts/test-native-consumer.sh
```

The C and Objective-C++ inspection consumers include only the public inspection header and verify source-level vtable/data resolution, snapshot paths, independent loader leases, owned errors, and symbol lifetime after releasing the original loader and runtime references. The script also checks the C consumer as strict C11. The C++ inspection consumer exercises wrapper copy/move, independent leases, copied snapshot descriptions, owned exceptions, and shared-runtime access. Two Objective-C++ inspection consumers verify C++ handle destruction in ARC and manual-reference-counted objects. The remaining backend fixtures check C/C++ calls, instance methods, receiver ownership, multiple-inheritance subobjects, reference arguments, non-trivial and indirect results, register/stack argument passing, concurrent resolution, and image retention after the original loader reference is released. Objective-C++ consumers additionally check selector signatures, ARC and manual-reference-counting lifetimes, initializer ownership, and block arguments/results. The dynamic C consumer checks libffi-backed calls with zero and twelve arguments, narrow scalar results, pointers, nested aggregate layouts and returns, retained type descriptions, and concurrent preparation/invocation. Separate Swift consumers link the public product and verify C/C++ calls, custom values, direct/virtual receiver calls, and image retention after releasing the original loader reference. C++ object tests cover explicit secondary-subobject views, borrowed result lifetime, nontrivial-value adapters, and bounded vtable access. Authentication code is additionally compiled for arm64e and compared with fixture-generated discriminators; this does not replace PAC runtime testing on a device. The Swift function and member consumers build a separate Swift library and call it after releasing the original loader reference. Member tests cover nominal metadata caching, generic metadata rejection, class/value/enum receivers, inherited implementations, initializer/setter ownership, static properties, and writeback after conversion failures. CI runs these consumers after the macOS package tests.

Build for another Apple platform by changing the generic destination:

```sh
xcodebuild build \
  -scheme ABIBridge \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

For watchOS, add `WATCHOS_DEPLOYMENT_TARGET=11.4` so dependencies also build within the supported deployment range. CI uses Xcode 26.6 on `macos-26` for macOS tests and iOS, visionOS, watchOS, and tvOS builds.

## Documentation

The supported consumer interfaces are the Swift `ABIBridge` module and the native headers documented in the DocC consumer guides, all linked through the `ABIBridge` product. Other native headers remain implementation details. SwiftPM may make transitive modules importable; that does not make their entire contents supported public API.

Describe public Swift API contracts in DocC comments. Put guides in the DocC catalog and keep the README at installation and quick-start level. Write prose without manual line wrapping.

Build the same static site that is published by CI:

```sh
bash scripts/build-documentation.sh
```

The default output is `.build/documentation`. Optional arguments select the output directory and hosting base path. The script validates ABIBridge's catalog with DocC warnings treated as errors, while dependency documentation warnings remain separate.

Pushes to `main` build and deploy the site to GitHub Pages. Pull requests run the package CI without a documentation job.

## Releases

The Release workflow validates an approved commit with the same CI used for pull requests, then publishes its draft automatically. Failed or cancelled validation leaves the draft unpublished. This Swift package is distributed through its Git tag and GitHub's source archives; there are no separately uploaded binary assets.

After reviewing the version, title, notes, full target commit SHA, and automatic publication plan, use Python 3, Git, and an authenticated GitHub CLI:

```sh
python3 scripts/release.py start v0.1.0 \
  --repo lynnswap/ABIBridge \
  --target <full-40-character-commit-sha> \
  --notes-file /path/to/release-notes.md
```

Replace the example version and target with the approved values. The title defaults to the version; use `--title` to set it explicitly or `--prerelease` for a prerelease. Authentication needs permission to create releases and dispatch workflows. The Release workflow must already exist on `main`. Merely saving a draft in the GitHub UI does not start Actions.

The command creates a draft pinned to the full SHA, or reuses an existing draft only when its target and content match. It then dispatches `release.yml` from main with the draft ID, target SHA, and content fingerprint. It reports the draft URL and dispatch acceptance; it does not wait for publication. The workflow checks out the target SHA for package tests and all four device-platform builds. Only the final job has publication permission, and it executes the release script from the workflow's main commit.

The publish job uses the repository's `GITHUB_TOKEN` by default. For arbitrary historical commits, configure the optional Actions secret `RELEASE_TOKEN` with a fine-grained PAT scoped to this repository and **Contents: write** plus **Workflows: write** (or a classic token with `repo` and `workflow`). GitHub can reject tag creation with the default token when the target's workflow files differ from current branch tips. The custom credential is used only in the publish step; tests receive no release secret. If that permission restriction occurs, the draft remains unpublished: configure the credential and rerun the failed publish job, keeping the same approved SHA. Repository tag rules still apply. See [GitHub's reference-creation permissions](https://docs.github.com/en/rest/git/refs#create-a-reference).

Do not edit the draft, upload assets, or move its tag while checks run. The workflow rejects uploaded assets and verifies the title, notes, prerelease state, tag name, and target again before publication. The publication request explicitly supplies those approved fields, so an intervening draft edit cannot substitute different release metadata. GitHub does not provide a transaction spanning tag references, release assets, and release publication; maintainers must serialize those external operations. A missing tag is created at the tested SHA only after checks pass; an existing lightweight or annotated tag must resolve to that SHA. Publication preserves the supplied notes and prerelease state. Stable releases use GitHub's legacy latest-release selection; prereleases are not marked latest.

If dispatch fails or its response is uncertain, inspect the Actions page before rerunning the same command, since GitHub may already have accepted it. Repeating the command reuses a matching draft. For a failed workflow, use GitHub's re-run controls after addressing the failure. A failed publication can leave the correct tag alongside a draft; rerunning the failed publish job resumes without moving the tag. A retry after successful publication is a no-op. Changed draft content needs a newly reviewed command matching that content; old workflow runs will not publish it.

Run the release protocol tests locally without creating any GitHub resources:

```sh
python3 -m unittest discover -s scripts -p 'test_release.py' -v
actionlint
```

## Pull requests

Keep each pull request independently buildable and link its issue. Include the behavior changed, relevant validation, and any unverified runtime behavior.
