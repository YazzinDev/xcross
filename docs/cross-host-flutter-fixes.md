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
