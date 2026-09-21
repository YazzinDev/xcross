# Cross-host Flutter build and debug fixes

This change targets Windows-hosted Flutter iOS builds and the shared debugger
and SwiftPM mechanisms. It is based on upstream
`00a55b0b765c50b2858b664a5abf006cdfda77b0`; it does not import the history or
application-specific documentation of the exploratory branch.

## Problems and changes

| Area | Technical condition | Change and regression coverage |
| --- | --- | --- |
| Apple tool shims | A native build hook invokes a copied xcrun without the parent process's SDK configuration. PATH resolution can also return a differently cased compiler name. | Record the selected SDK alongside the copied executable; answer SDK/platform probes before configuration initialization and resolve supported sibling tool names exactly. Version probes report the release version or numeric development version rather than an unparseable source-build label. Tests cover sidecar creation, lookup, absent tools and fallback. |
| SwiftPM environment | SwiftPM resolves xcrun through the child PATH rather than through the configured launcher. | Prefer a present bundled xcrun on Windows. Use a PATH **list** separator, not a filesystem separator. Missing bundles and POSIX environments retain their previous behavior. |
| Imported SDK layout | Platform/toolchain descriptors are omitted, and materializing an SDK directory alias creates two apparent SDK installations. | Import descriptors for the selected SDK subset; materialize links before removing matching unversioned directory aliases. Synthetic tests exercise both alias directions and preserve nested link contents. |
| Build-plan location | A cold build can create its description in a different layout from an earlier run. | Invoke the existing upstream build-directory resolver after generating the plan. Do not add a second resolver or a second build-backend selection policy. |
| Generated Swift headers | A reachable internal Swift target has a module map referencing an absent generated header but is not a public package product. | After an aggregate failure, include observed internal targets in the existing header recovery. Preserve reachability filtering and propagate target compilation errors. Tests cover internal targets, unreachable targets and error propagation on both host lanes. |
| Swift availability | Disabling availability checking can remove runtime guards around weak-linked APIs on older target systems. | Remove the global compiler flag on all hosts and advance the plugin cache version so previously compiled libraries cannot bypass the correction. The existing argument test now forbids the flag; existing fingerprint tests remain in place. |
| Native hook frameworks | Flutter can write frameworks under the project build directory rather than the assemble output directory. | Collect both output locations and pass discovered frameworks through the existing thinning, binary-repair, embedding and Runner-linking pipeline. Tests use synthetic framework names and inspect actual linker arguments. |
| Native asset manifest | Windows separators describe the build host, but the manifest is consumed by iOS. | Normalize only path-bearing `absolute`/`relative` iOS entries. Preserve asset IDs, other lookup modes, non-iOS entries and byte-identical unchanged manifests. Tests include multiple iOS architectures and idempotence. |
| Debug Info.plist | The non-Xcode packer misses Debug configuration overrides and Flutter's development-only network declarations. | Apply Generated then Debug xcconfig values, retaining explicit CLI override precedence. Add the VM Bonjour service and a missing local-network usage description without replacing existing values. Tests cover priority, preservation and idempotence. |
| GDB negotiation | No-ack mode is requested but its final acknowledgement is omitted, or a rejection is silently accepted. | Acknowledge the response and require `OK` before sending further requests. Socket-backed tests exercise successful and rejected negotiation. |
| Debugger stops | An attach/resume race can lose a stop packet; expected pauses must be continued without resuming fatal faults. | Subscribe before the first resume and continue only stops already classified as nonfatal by upstream. Preserve the conservative upstream fatal classification, add Mach fault descriptions and test that a memory fault is not continued. No raw packet dumps are added. |
| Flutter launch arguments | CoreDevice does not supply the Flutter tooling switch required by the iOS Debug embedder. | Pass `--enable-dart-profiling` with Flutter VM-service arguments. This remains a Debug/JIT build, not a profile build; native launch arguments remain unchanged. |

### Implementation map

- `packages/xcross/bin/xcrun.dart` and
  `packages/xcross/lib/src/flutter/build/internal/apple_tool_shims.dart` own
  copied-tool discovery and the SDK sidecar.
- `packages/xcross/lib/src/cli/basic/sdk_install.dart` owns extraction metadata
  and materialized SDK directory aliases. It does not modify the input archive.
- `packages/xcross/lib/src/flutter/build/ios_plugin_package.dart` owns the
  child environment, compiler/cache policy, build-plan selection, generated
  header recovery and checkout symlink verification.
- `packages/xcross/lib/src/flutter/build/internal/native_asset_frameworks.dart`
  collects hook outputs. `internal/native_assets_manifest.dart` is a pure
  manifest transformation; `ios_native_assets.dart` calls it before packaging.
- `packages/xcross/lib/src/flutter/build/flutter_packer.dart` passes framework
  products to `runner_shim.dart` and applies the helpers in `info_plist.dart`.
  Existing upstream binary repair and linker diagnostics remain intact.
- `packages/dart_mobile_device/lib/src/gdb_remote_client.dart` owns protocol
  negotiation and stop descriptions. The xcross device layer owns subscription
  ordering, stop handling and Flutter-specific launch arguments.

## Platform boundary

The SDK importer intentionally still selects the existing iPhoneOS subset.
iPhone and iPad device builds use that same SDK; adding simulator or other Apple
OS build support is not part of this change. However, duplicate-alias detection
does not depend on an iPhoneOS name: tests cover the same structural layout for
device, simulator, television and desktop SDK names. It only recognizes matching
versioned/unversioned directories directly under `SDKs`, within the imported
bundle; unrelated links and distinct versions are not removed.

Native-manifest normalization applies to all `ios_*` entries, not a single
architecture. Other OS entries are preserved because this builder produces iOS
bundles. Swift availability and debugger protocol correctness are host-independent.
Internal-header recovery remains structural on both host lanes; the new code
does not add a catch-all Windows retry.

## Exploratory changes intentionally not carried over

The exploratory changes were classified by their technical purpose:

- **Generic bug fixes:** tool discovery, symlinks, imported SDK layout, availability,
  native assets, plist generation and debugger negotiation/order were retained
  or reimplemented as described above.
- **Generic compatibility improvements:** internal-header recovery is based on
  module-map evidence and dependency reachability, not target identity. SDK
  alias handling is based on the versioned-directory relationship, not a single
  platform name. Existing upstream plan/backend support is reused.
- **Identity-based manifest bootstrap:** not ported. Replacing a named remote
  dependency with a local path before unified resolution bypasses part of the
  resolver's version/identity semantics. Simply doing this for every exact pin
  would not validate constraints imposed elsewhere in the graph. The existing
  host-manifest normalization remains unchanged; a general pre-resolution
  repair would need a separate design preserving SwiftPM's full resolution
  semantics. This PR does not claim to solve every invalid remote manifest.
- **Broad target-build fallbacks and forced platform registration:** not ported.
  Current upstream already selects the native build backend. Continuing after
  arbitrary target compilation errors could hide real failures. The included
  recovery still propagates a failing target and does not invent missing outputs.
- **Timeout increases:** not ported. The VM-service readiness budget is unchanged;
  a larger budget is not a fix for an app that faults before starting its VM.
- **Scene-bootstrap experiments:** not ported. The final programmatic window/
  controller order was already present in the selected upstream base. Additional
  view subclasses, startup markers and raw debugger dumps were investigation
  aids, not necessary behavioral changes.
- **Verbose child-command additions:** not ported. Existing xcross diagnostics
  remain intact; this change adds no new command or filesystem dumps.
- **Environment/application actions:** no SDK installation, credential reset,
  tunnel management, application configuration or custom native host integration
  is part of this patch. No private dependency fixtures or development logs are
  included.

## Repository conventions and research

The repository has no dedicated CONTRIBUTING file at the selected base.
Its README welcomes contributions; `analysis_options.yaml` defines the Dart
style, and `.github/workflows/release.yml` runs analysis and all six workspace
package test suites. The existing `@visibleForTesting`/synthetic fixture patterns
are used, with no new runtime dependencies or CI policy changes.

The design was checked against the public
[Troubleshooting guide](https://xcross.sh/docs/troubleshooting/) and
[FAQ](https://xcross.sh/docs/faq/): setup/tunnel/authentication problems retain
their existing mechanisms, and this remains the Debug/JIT SwiftPM build path.
Relevant merged changes reviewed before implementation:

- [#47: Windows native assets and SwiftPM](https://github.com/arxdeus/xcross/pull/47)
  — existing shim, workspace and cross-host build boundaries.
- [#54: incremental artifact staging](https://github.com/arxdeus/xcross/pull/54)
  — preserve unchanged outputs rather than rewriting them every run.
- [#76: device crash reporting](https://github.com/arxdeus/xcross/pull/76)
  — retain actionable fault reporting without new investigation dumps.
- [#78: SDK/linker compatibility](https://github.com/arxdeus/xcross/pull/78)
  — reuse current build-directory/backend support and preserve the newer
  SDK and Mach-O repair mechanisms.

## Validation and limitations

Run the focused tests from the repository root:

```sh
dart test packages/dart_mobile_device/test/gdb_remote_client_test.dart packages/xcross/test/device/session_console_stop_test.dart packages/xcross/test/device/core_device_launch_profile_test.dart packages/xcross/test/flutter/build/ios_plugin_package_test.dart packages/xcross/test/flutter/build/native_assets_manifest_test.dart packages/xcross/test/flutter/build/native_asset_linking_test.dart packages/xcross/test/flutter/build/swiftpm_cross_host_test.dart packages/xcross/test/cli/sdk_command_test.dart packages/xcross/test/cli/sdk_platform_layout_test.dart packages/xcross/test/cli/xcrun_test.dart packages/xcross/test/flutter/build/info_plist_test.dart packages/xcross/test/flutter/build/ios_native_assets_test.dart
```

Broader validation follows the release workflow: `dart analyze`, `dart format`
on changed Dart files, and `dart test` for each workspace package. Run the
`apple_developer_kit` suite from that package directory, as in Windows CI.

Windows validation on 2026-09-21:

- The final focused suite passed **225 tests**.
- The final five-package broad run passed **1,222 tests** and skipped 10, with five failures.
  Those same five failures reproduced on an isolated, unchanged upstream checkout:
  three terminal-mode tests run without an interactive console, plus two Compose
  tests requiring the uninitialized examples submodule. No test was disabled or
  weakened to conceal these failures.
- The separate signing package suite passed 166 tests with one skip.
- All 25 changed Dart files pass the repository formatter and targeted static
  analysis with no issues. Both the CLI and xcrun entrypoints compile to native
  Windows executables in a temporary output directory; installed binaries and
  stored authentication are not replaced.
- Whole-workspace analysis reports one pre-existing `prefer_initializing_formals`
  warning in `config_command.dart:41`. That file is byte-identical to the upstream
  base, and the same warning reproduced in isolated baseline analysis;
  unrelated configuration code is intentionally unchanged.

Follow-up device validation on 2026-09-21 used this generalized branch's complete
Windows bundle, built with `dart run tool/build_xcross.dart`. Both `xcross flutter
build` and `xcross flutter run` succeeded against a real Flutter application:
signing reused the existing login, installation completed on a physical iPhone,
the debugger attached, the VM Service connected, and a requested hot reload
completed in 0.1 seconds. The user also confirmed the application was working.

This run reused existing local SDK and dependency caches; it does not establish
clean-machine reproducibility or Linux/macOS CI compatibility. Early host
evaluation of an invalid remote manifest remains outside the included fixes.
Maintainership review and the public cross-host integration matrix remain
important before merge.

## Follow-up: Windows binary-framework directory copy (2026-09-22)

### Trigger and reproduction boundary

A staged reproduction based on release `v1.4.5` (`820cc890`) exposed an additional
failure after SDK/tool-shim fixes, dangling-symlink handling, and the native
SwiftPM backend selection from upstream `00a55b0` had been applied. A local-only
remote-manifest override was also necessary to pass the earlier Sentry `getenv`
failure; that override is **not** part of this PR. This is a newly reproduced
downstream blocker, not the first error from an unchanged release executable.

Environment: Windows x64, Swift 6.4.0 `NoAsserts`, Dart 3.11.5 / Flutter 3.41.7,
installed iPhoneOS 26.5 SDK, Debug/JIT build. App/pub/xcross caches were isolated;
the existing SDK and global Git download cache were retained.

The failure repeated on an unchanged second attempt. Exact relevant log lines
below retain the dependency name; only the private workspace prefix is redacted:

```text
[1/4] Copying RecaptchaEnterpriseSDK.framework
error: <workspace>\scratch\arm64-apple-ios\debug\RecaptchaEnterpriseSDK.framework is not a directory
```

The failing operation was `swift-build --build-system native ... --target
RecaptchaEnterprise`. The deprecated-backend and conflicting-package-identity
warnings were separate from this fatal copy error. The source framework was
populated, while the destination was left as an empty ordinary directory.

### Cause, chosen correction and alternatives

The generated `description.json` contained a directory copy source with an
extended Windows drive prefix (`\\?\C:\...`). A standalone Foundation
`FileManager.copyItem(at:to:)` probe failed for that source; the error showed a
malformed `/?/C:/.../Headers` URL path and Win32 error 123. The same source without
the extended prefix copied successfully. No source contents were changed.

SwiftPM's [CopyCommand](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/Build/LLBuildCommands.swift)
reads its copy inputs from the build description. Normalizing only the affected
directory input in that description allowed the actual target to finish:

```text
[0/3] Copying RecaptchaEnterpriseSDK.framework
[4/5] Emitting module RecaptchaEnterprise
[5/5] Compiling RecaptchaEnterprise RecaptchaInteropBidings.swift
Build of target: 'RecaptchaEnterprise' complete! (11.09s)
```

The first manual probe was overwritten by SwiftPM replanning and still failed;
the second probe, applied to the current plan, succeeded. This is why the fix
belongs in the existing generated-file repair lifecycle, including its bounded
repair-and-retry path, rather than as a one-time cache edit.

- **Chosen:** normalize extended drive-qualified directory copy inputs in
  `description.json` on Windows. Leave command keys, output nodes, the llbuild
  YAML, file copies, ordinary paths and UNC paths unchanged. Preserve unchanged
  descriptions byte-for-byte and make repeated repair a no-op.
- Shortening or relocating every cache could avoid some long paths but changes
  unrelated cache behavior and does not correct an already generated plan.
- Pre-copying frameworks or ignoring the failing target would bypass SwiftPM
  dependency tracking or conceal genuine build errors; neither is used.

There is no framework-name, dependency-version or app-specific branch in the fix.
Authentication, signing storage, SDK installation and source checkouts are not
modified by it.

### Files, commits and validation

- PR fix: `802fc6f`; equivalent release-reproduction step: `85ec1a6`.
- `packages/xcross/lib/src/flutter/build/ios_plugin_package.dart` extends
  `repairWindowsGeneratedBuildFiles` with scoped copy-source normalization.
- `packages/xcross/test/flutter/build/windows_directory_copy_test.dart` covers
  long paths on a non-C drive, unchanged node identities, unrelated fields,
  ordinary/UNC/file paths, Windows-only invocation and idempotence.
- The focused plugin-package and new regression suites passed **117 tests** on
  the PR branch. The same selection passed 116 on the older reproduction base.
- Both the complete reproduction and PR CLI bundles rebuilt successfully;
  targeted Dart analysis reports no issues. The real affected
  SwiftPM target passed after normalizing its generated copy input, as above.

This evidence establishes the directory-copy repair, not a new full application
or device validation. The earlier remote-manifest blocker remains outside this
PR; subsequent reproduction stages must be reported separately.

## Follow-up: oversized Windows Swift compiler command (2026-09-22)

After the directory-copy repair, the release-based staged app build reached
the aggregate plugin module, then failed before starting its compiler:

```text
error: command Compiling Swift Module 'FlutterPluginsGenerated' (1 sources) failed: unable to spawn process '<toolchain>\swiftc.exe' (Der Dateiname oder die Erweiterung ist zu lang.
)
```

Only the toolchain prefix above is redacted. The executable path was 90 characters;
the build description's 600 additional arguments alone totaled 34,470 characters,
already exceeding Windows' 32,767-character process command-line limit. Shorter
cache paths would only postpone this failure for larger dependency graphs.

Fix `a6d0a4d` (reproduction equivalent `606db5b`) extends the existing Windows
generated-file repair lifecycle in `ios_plugin_package.dart`. Oversized inline
`swiftc` argument arrays in scratch YAML plans are replaced with a content-addressed
response file under `.xcross-response`. Arguments retain their order, with Windows
quoting for spaces, quotes, empty arguments and trailing backslashes. Command keys,
inputs and outputs remain intact; short commands and other executables are left
unchanged. The existing repair/retry handles SwiftPM regenerating the plan.

The threshold is 28,000 unquoted characters, leaving headroom below the Windows
limit for ordinary argument quoting. This is scoped to Swift compiler invocations,
not a general repair for all possible long subprocess commands.

Validation: the actual previously failing compiler argv was externalized and
executed successfully (exit 0), including both compile and emit-module jobs. The
final probe used a response-file path containing spaces and reduced the launch
command to 243 characters. `windows_swift_response_test.dart` verifies encoding,
argument order, unchanged commands and idempotence. The two Windows regression
files pass four tests on the PR branch; targeted analysis on the reproduction
branch is clean. The reproduction bundle rebuilt successfully.

The local raw probe is `build/reproduction-evidence/response-file-target-final.log`;
it is not published because it contains private application paths. This proves
the compiler-launch fix, not completion of a new end-to-end app/device build.
The cumulative app rerun is recorded separately as `stage-08-response-files.log`
and retains the previously disclosed local-only remote-manifest override.

Local follow-up guard (`6149791`, reproduction `f30afdd`): the response-file
helper itself now returns before any filesystem access unless running on Windows,
in addition to the existing Windows guard on its caller. The test-only host
override verifies that a non-Windows invocation leaves YAML bytes unchanged and
creates no response directory. The directory-copy rewrite remains inside the
same Windows-only generated-file repair entry point; its string transformer has
no filesystem side effects. The focused PR suite passes 118 tests. This is a
simulated non-Windows branch test, not an actual Linux/macOS build.

This guard is held locally pending complete application-build validation; no
additional push is authorized before that validation is reviewed.

The stage-8 cumulative app run subsequently failed during the `FirebaseAuth`
prebuild with Swift exception 5 and a duplicate `Foundation` module diagnostic
showing two visually identical PCM paths. Its cause is not yet established.
The successful isolated aggregate compiler probe must not be presented as a
successful full application build. The guard follow-up remains local.

The subsequent full reproduction-branch build with the explicit guard completed
successfully (`stage-09-windows-guard.log`, exit 0): SwiftPM finished in 7m28s,
Runner compiled in 1.1s, and `app.app` was written. No caches were cleared between
the failed stage 8 and this control. The Foundation failure did not recur; its
cause remains unproven. Both guard-enabled CLI bundles rebuilt, but this full app
run used the reproduction bundle, not the full PR branch bundle. It retained
the previously documented staged patches and remote-manifest override. No device
launch or native Linux/macOS build was performed. Guard/documentation commits
have not been pushed since the user's request to validate locally first.

## Full PR-branch build validation (2026-09-22)

The complete `codex/upstream-windows-ios` bundle was rebuilt from `bd94046`
with `dart run tool/build_xcross.dart` in `packages/xcross`. Its executable SHA-256
was `ac95e7db694de4b667591eb89b46a990cfa859fb7b07092705f439254f34ce35`.
The subsequent `6c04567` changes only test formatting; runtime source is unchanged.

Using this PR bundle (not the reproduction bundle), `xcross flutter build
--dart-define-from-file=config/development.remote.env` completed with exit 0.
SwiftPM finished in 8m22s, Runner compiled in 1.1s, and `app.app` was produced.
The running SwiftPM invocation did not contain `-disable-availability-checking`.
The previously failing FirebaseAuth, framework-copy and aggregate plugin phases
were passed. No new device install, launch or hot-reload test was requested.

The full focused PR suite now passes **229 tests**. Targeted analysis of all
**27 changed Dart files** reports no issues, and all 27 pass formatting after
the test-only correction. The user-owned untracked `.idea/` directory is untouched.

This used the same isolated application copy, pub/xcross caches, installed SDK
and disclosed local Sentry manifest override as the staged runs. Therefore it
validates the complete PR runtime changes in that environment, **not** a clean
unmodified-dependency build or native Linux/macOS compatibility. The override
is not included in the PR. The previous intermittent Foundation diagnostic did
not recur; this does not establish its cause or a dedicated fix for it.

Raw evidence is retained locally as `stage-10-pr-branch.log` and copied to the
ignored `build/reproduction-evidence/` directory. No private application logs or
configuration are committed. All new preparation and validation commits remain
local, as requested; no further GitHub push has been made.
