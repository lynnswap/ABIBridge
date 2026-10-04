# Contributing

Use a Mac with Xcode and Swift 6.3 or later. Create a topic branch and open your pull request against `main`. Run the commands below from the repository root unless a command changes directories.

## Select Xcode

CI checks Xcode 26.6 and 27.0. To choose an installed version for your shell, set `DEVELOPER_DIR` and confirm the toolchain:

```sh
export DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer
xcodebuild -version
xcrun swift --version
```

For Xcode 26.6, use `/Applications/Xcode_26.6.app/Contents/Developer`. Adjust the path if your local installation has a different name.

## Format Swift code

Use the formatter included with Xcode. The repository's `.swift-format` configures both formatting and linting with four-space indentation. Multiline argument lists use one argument per line.

```sh
xcrun swift format --in-place path/to/File.swift
xcrun swift format lint --strict path/to/File.swift
```

Format the Swift files you change before submitting a pull request. Unicode identifiers remain allowed for ABI fixtures, and explicit initializers are retained when they define access across module boundaries.

## Test a change

Start with the manifest and whitespace checks:

```sh
xcrun swift package dump-package
git diff --check
```

For code changes, run the package tests and the additional checks relevant to the code you changed. Documentation and workflow changes can use the checks in their respective sections below.

### Package tests

The package has separate schemes for runtime contracts, public API behavior, and local workloads:

```sh
bash scripts/test-package.sh runtime
bash scripts/test-package.sh api
bash scripts/test-package.sh local
```

`runtime` runs `ABIBridgeCoreTests` and `ABIBridgeRuntimeTests` under the `ABIBridgeRuntime` scheme. `api` runs `ABIBridgeTests` under `ABIBridge`. `local` runs hook benchmarks and closure handoff stress tests under `ABIBridgeLocal`. Use `all`, or omit the argument, to run all three schemes sequentially, including local workloads.

Each selection uses its own directory under `.build/package-tests`. Set `ABI_TEST_BUILD_DIR` to reuse another directory across sequential runs; do not share it between simultaneous builds. The script forwards extra arguments to `xcodebuild`.

The Runtime and public API test bundles disable parallel execution in their shared schemes. They load and unload libraries in the process-wide image catalog; an absence check needs that catalog to remain stable while it runs. Individual tests still exercise concurrent operations where that is the contract. A suite's `serialized` trait does not isolate it from unrelated suites; see [Swift Testing parallelization](https://developer.apple.com/documentation/testing/parallelization).

During development, select a single suite:

```sh
bash scripts/test-package.sh api \
  -only-testing:ABIBridgeTests/ManagedSwiftValueTests
```

For changes to value handling, ownership, or calling conventions, also run the affected suites with `-configuration Release`. The focused external consumer check below verifies native C linkage in Release.

### Native consumers and ABI checks

When changing native headers, symbol lookup, call marshalling, or hooks, run the external consumer suite:

```sh
bash scripts/test-native-consumer.sh
```

This builds C, C++, Objective-C++, and Swift clients of the public product. It also runs the Swift compiler probes, which inspect generated code for argument passing, results, ownership, and pointer authentication across architectures.

For the subset used by CI, run `bash scripts/test-native-consumer.sh focused`. It checks external headers, optimized C linkage, and compiler-sensitive Swift entry points. `bash scripts/test-native-consumer.sh swiftui` runs the public SwiftUI consumer and its contract check. Set `ABI_CONSUMER_BUILD_DIR` to choose a separate build directory for another toolchain.

Run the architecture fixtures and the trampoline comparison when changing ABI handling:

```sh
(
  cd Tests/ArchitectureValidation
  xcodebuild test -scheme ArchitectureValidation-Package \
    -destination 'platform=macOS,arch=arm64'
)
python3 scripts/check-architecture-codegen.py
```

The comparison checks arm64 and arm64e by default and writes its output to `.build/architecture-codegen`. With Xcode 27, add `--architectures arm64 arm64e arm64e.x1` to include the newer ABI. Compiler probes check generated code; execution on matching hardware requires a separate device run.

### iOS Simulator and platform builds

Run the lower runtime contracts on an installed iOS Simulator runtime:

```sh
python3 scripts/test-simulators.py --platforms iOS \
  --scheme ABIBridgeRuntime --skip-swiftui-build
```

The helper creates a dedicated device, runs tests without parallel destination clones, and deletes the device afterward. Omitting `--scheme` selects the public `ABIBridge` suite; omitting `--skip-swiftui-build` also builds `ABIBridgeSwiftUI`. It prefers a runtime matching the selected Xcode SDK and saves builds in `.build/simulator-tests` and results in `.build/simulator-results`. Tests that compile temporary libraries on the host run only on macOS.

Use `--platforms iOS tvOS` to choose another combination. Omitting `--platforms` runs all four Simulator platforms sequentially; CI selects only iOS.

For SDK or platform changes, build the affected device target:

```sh
xcodebuild build -scheme ABIBridge \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Replace `iOS` with `visionOS`, `watchOS`, or `tvOS` as needed. For watchOS, add `WATCHOS_DEPLOYMENT_TARGET=11.4` so dependencies use the supported deployment range. Repeat with `-scheme ABIBridgeSwiftUI` when changing the optional SwiftUI product.

### CI and release automation

Check changes to workflows or their Python helpers without creating GitHub resources:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py' -v
actionlint -ignore '^label "xcode-27" is unknown\.'
```

Older `actionlint` versions do not recognize GitHub's [official `xcode-27` runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). The command ignores that specific warning and still checks other runner labels.

## What CI runs

[CI](.github/workflows/ci.yml) runs Core and Runtime together in four environment entries:

| Xcode | Runner | Runtime environments | Additional checks |
| --- | --- | --- | --- |
| 26.6 | `macos-26` | macOS and iOS Simulator | Focused external consumers on macOS |
| 27.0 | `xcode-27` | macOS and iOS Simulator | Public API suite and focused external/SwiftUI consumers on macOS |

The public API suite runs once in the macOS/Xcode 27 job, reusing the runtime build directory. A separate Xcode 27 job builds both products for the iOS, visionOS, watchOS, and tvOS device SDKs. Timing loops, long repetition, full external integration combinations, and architecture probes remain local checks.

The matrix checks compiler and OS assumptions in metadata, calling conventions, and image loading. Focused external Swift clients also exercise generic public entry points that contain compiler workarounds. The `xcode-27` runner runs macOS 27 and is currently in public preview. Simulator execution does not verify device pointer authentication.

Independent checks continue after failures. CI keeps failed package and Simulator diagnostics for seven days. Pull requests and releases require every CI job to succeed; closing a pull request cancels its superseded validation. Older release targets without the runtime target use their original package and consumer suites. DocC builds run separately with Xcode 27.0 when `main` changes.

See [Runtime boundaries and CI coverage](Docs/RuntimeArchitecture.md) for module responsibilities, ownership, and the test contracts behind this split.

## Find the relevant fixtures

| Location | Purpose |
| --- | --- |
| [Tests/ABIBridgeCoreTests](Tests/ABIBridgeCoreTests) and [Tests/ABIBridgeRuntimeTests](Tests/ABIBridgeRuntimeTests) | Environment-dependent native and Swift runtime contracts |
| [Tests/ABIBridgeLocalTests](Tests/ABIBridgeLocalTests) | Local hook benchmarks and closure stress |
| [Tests/ABIBridgeTests](Tests/ABIBridgeTests) | Package tests organized by API and behavior |
| [Tests/NativeConsumer](Tests/NativeConsumer) | External clients that import and link the public product |
| [Tests/ManagedSwiftFixtures](Tests/ManagedSwiftFixtures) and [Tests/ManagedSwiftAdapters](Tests/ManagedSwiftAdapters) | Separately compiled Swift types and adapters, including library-evolution boundaries |
| [Tests/ArchitectureValidation](Tests/ArchitectureValidation/README.md) | Architecture probes, device modes, and recorded execution results |
| [scripts](scripts) | Compiler probes, build helpers, and automation |

Use the [DocC guides](Sources/ABIBridge/ABIBridge.docc/ABIBridge.md) for API contracts and supported behavior. Keep detailed test cases with their fixtures and device observations in the architecture validation guide.

## Run on a physical device

Open `ABIBridge.xcworkspace`, select `ArchitectureTestHost`, choose your development team and a connected iOS device, then run. The host uses Release by default. Choose a probe in the app, or add `--probe swift-callback` under **Edit Scheme → Run → Arguments** to select one at launch.

For a specific architecture, use the helper so the setting applies to the app and every package dependency:

```sh
bash scripts/build-device-validation.sh arm64e \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates
```

The helper accepts `arm64`, `arm64e`, and `arm64e.x1`, followed by extra `xcodebuild` options. For arm64e.x1, use Xcode 27 or later and consult the [recorded build-service requirements](https://github.com/lynnswap/ABIBridge/issues/103#issuecomment-5846529137). Those build results do not establish a fix in Xcode's bundled service or execution on matching hardware.

Set `ABI_VALIDATION_CONFIGURATION=Debug` for a diagnostic build. For compilation without signing, pass `CODE_SIGNING_ALLOWED=NO`. Default products are under `.build/device-validation/<architecture>/Build/Products/Release-iphoneos`.

Run probes in separate launches. Each writes `Documents/architecture-<mode>.json`, which can be shared from the result view. A start marker alone means the probe did not finish. Report protected-memory refusal separately from successful mutation. Neither a device build nor Simulator execution verifies device pointer authentication.

The hidden `tamper` probe intentionally corrupts a pointer signature. Run it separately after `native` passes with `pacCompiled: true` in the same build; verify the expected authentication failure in the crash report. A generic crash is insufficient. See the [architecture validation guide](Tests/ArchitectureValidation/README.md) for probe details and execution evidence. Keep credentials, provisioning profiles, and device identifiers out of the repository.

## Update documentation

The public interfaces are the `ABIBridge` Swift module, the native headers described in the consumer guides, and the optional `ABIBridgeSwiftUI` product. Other native headers and transitively importable modules remain implementation details.

Describe public API contracts in DocC comments and longer guides in the relevant module's DocC catalog. Keep the README focused on installation and quick-start examples. Write prose without manual line wrapping.

Keep module landing pages brief. In the ABIBridge catalog, place guides and top-level symbols in the feature collections linked from `ABIBridge.md`; Swift values and callbacks belong in `SwiftValues` under `SwiftCalls`. Use `Topics` for the primary hierarchy and inline or `See Also` links for related features. Preserve article filenames so published URLs remain stable.

Build the static site locally:

```sh
bash scripts/build-documentation.sh
```

The script merges both module catalogs into `.build/documentation` and treats their DocC warnings as errors; dependency warnings remain separate. Optional arguments select the output directory and hosting base path. Pushes to `main` deploy the site to GitHub Pages. Pull requests do not run a documentation job.

## Measure performance

Run the Release benchmarks without other builds or tests competing for resources:

```sh
bash scripts/benchmark-runtime.sh calls
bash scripts/benchmark-runtime.sh search
bash scripts/benchmark-runtime.sh hooks
```

`calls` measures prepared native calls and callbacks. `search` measures lookup, demangling, and pointer discovery over generated fixtures. `hooks` measures Objective-C managed hooks and replacement entries through the local test scheme. Record Xcode, machine, configuration, and workload with the results. These benchmarks do not establish application latency or physical-device performance.

## Submit a pull request

Keep each pull request independently buildable and link its issue. Explain the behavior changed, the relevant validation, and any runtime behavior you have not verified. For ABI changes, distinguish compiler-probe results, Simulator tests, and physical-device execution.

## Publish a release

Releases use Git tags and GitHub source archives, without uploaded binary assets. The [Release workflow](.github/workflows/release.yml) validates an approved commit with CI, then publishes its draft automatically. Failed or cancelled validation leaves the draft unpublished.

### Start an approved release

Review the version, title, notes, full target SHA, and automatic publication plan before running the command. You need Python 3, Git, and an authenticated GitHub CLI with permission to create releases and dispatch workflows. The Release workflow must already exist on `main`.

```sh
python3 scripts/release.py start v0.1.0 \
  --repo lynnswap/ABIBridge \
  --target FULL_40_CHARACTER_COMMIT_SHA \
  --notes-file /path/to/release-notes.md
```

Replace the example values with the approved ones. The title defaults to the version; use `--title` to change it or `--prerelease` for a prerelease.

The command creates or reuses a matching draft and dispatches validation from `main`. It reports the draft URL and dispatch acceptance without waiting for publication. Saving a draft in the GitHub UI does not start the workflow.

### While validation runs

Leave the draft, assets, and tag unchanged. Before publication, the workflow rechecks the approved metadata and requires any existing tag to resolve to the tested SHA. If no tag exists, publication creates it after validation succeeds. Only the publish job receives publication credentials; it runs the release script from the workflow's `main` commit. Stable releases use GitHub's legacy latest-release selection; prereleases are not marked latest.

### Recover from a failure

| Situation | Next step |
| --- | --- |
| Dispatch failed or its response is uncertain | Check Actions before repeating the command; GitHub may have accepted it. A repeat reuses a matching draft. |
| Validation failed | Address the failure and use GitHub's re-run controls. A different target SHA needs approval again. |
| Publication failed after creating the tag | Rerun the failed publish job with the same approved SHA; it resumes without moving the tag. |
| Draft content changed | Review the new content and start a matching command. Older runs will not publish it. |
| Publication already succeeded | A retry is a no-op. |

The publish job normally uses `GITHUB_TOKEN`. GitHub may reject tag creation for a historical commit whose workflow files differ from current branch tips. In that case, configure `RELEASE_TOKEN` with a repository-scoped fine-grained PAT granting **Contents: write** and **Workflows: write**, or a classic token with `repo` and `workflow`, then rerun the failed publish job. Repository tag rules still apply. See [GitHub's reference-creation permissions](https://docs.github.com/en/rest/git/refs#create-a-reference).
