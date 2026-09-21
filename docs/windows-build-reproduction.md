# Windows build reproduction: errors and fixes

Tested on 2026-09-21/22: Windows x64, xcross **v1.4.5**, Flutter 3.41.7,
Dart 3.11.5, Swift 6.4.0 NoAsserts, imported iPhoneOS 26.5 SDK.

Command from the app directory:

```powershell
xcross flutter build --dart-define-from-file=config\development.remote.env
```

Only step 1 uses the **unmodified release**. Later steps apply patches
incrementally. The app's pubspec and lockfile remain unchanged. App/pub/xcross
caches are isolated and reused; the installed SDK and global SwiftPM Git cache
are retained. These are not independent clean-machine builds.

**Log convention:** Fenced blocks contain selected original log lines. Private
path prefixes are abbreviated using `<tools>`, `<workspace>`, `<checkout>`,
`<toolchain>` and `<app>`. Each step names its raw source log.

## 1. Unmodified release: SDK probe

**What happened:** Both installed and downloaded v1.4.5 binaries stopped during
native assets. Logs: `build.log`, `installed-release-control.log`.

**Error:**

```text
Unhandled exception:
Bad state: No element
```

The stack identifies `firstLineOfStdout` in `objective_c-9.6.0/hook/build.dart:198`
and `sdkPath` at line 189. The hook received no usable stdout from
`xcrun --show-sdk-path --sdk iphoneos`.

**Fix:** Supply the copied shim with an SDK sidecar and answer SDK probes before
user configuration lookup. The next run passed this probe. PR commit: `56623f4`.

## 2. After the SDK fix: compiler discovery

**What happened:** The native tool resolver reached compiler discovery.
Log: `stage-01-sdk-sidecar.log`.

**Error:**

```text
Tool instance file:///<tools>/clang.EXE not recognized.
```

**Fix:** Return the existing adjacent `clang.exe` shim with its exact spelling
instead of the PATH/PATHEXT-derived `clang.EXE`. The next run recognized the
compiler. PR commit: `56623f4`.

## 3. After compiler discovery: version probe

**What happened:** The resolver called `xcrun --version`.
Log: `stage-02-tool-spelling.log`.

**Error:**

```text
xcrun: no Darwin SDK installed; run `xcross sdk install` first
System not configured correctly: `<tools>\xcrun.exe --version` returned unexpected exit code: 1.
```

**Fix:** Return a numeric version before configuration lookup; this probe does
not need SDK discovery. Native assets then completed. PR commit: `56623f4`.

## 4. After native assets: Sentry manifest

**What happened:** SwiftPM evaluated the remote manifest on Windows.
Log: `stage-03-version-probe.log`.

**Error:**

```text
C:\Package@swift-6.1.swift:71:11: error: cannot find 'getenv' in scope
```

**Local workaround, not a PR fix:** Add the Windows CRT import to the manifests
of a local sentry-cocoa **8.58.3** checkout (`dad229c665bfd043c5d80ac7aa77717cbd19a1c3`).
Point only the isolated `sentry_flutter` 9.21.0 Swift manifest at that checkout.
This exposes `getenv` before resolution; post-vendoring normalization is too late.

**All subsequent builds retain this override. PR #79 does not fix this error.**

## 5. After the manifest workaround: Git symlink validation

**What happened:** xcross rejected a dangling purchases-ios-spm example symlink.
Log: `stage-04-manifest-override.log`.

**Error:**

```text
error: Symlink target does not exist in SwiftPM checkout: <checkout>\Examples\LegacySwiftExample -> <checkout>\Tests\TestingApps\PurchaseTester
```

**Fix:** Validate real Git symlinks by their stored target text without requiring
the target to exist. Retain existence checks for hard-link fallbacks. Checkout
validation then passed. PR commit: `56623f4`.

## 6. After checkout validation: build-plan location

**What happened:** Swift 6.4's default backend wrote the description under
`scratch/out/debug`, while the release expected the native backend's directory.
Log: `stage-05-dangling-links.log`.

**Error:**

```text
error: Cannot read planned Swift interop headers from <workspace>\scratch\arm64-apple-ios\debug\description.json: PathNotFoundException: Cannot open file, path = '<workspace>\scratch\arm64-apple-ios\debug\description.json' (OS Error: Das System kann den angegebenen Pfad nicht finden, errno = 3)
```

**Fix:** Select `--build-system native`. Plan lookup then passed. This is
**upstream `00a55b0` / PR #78**, already in PR #79's base, not our new fix.

## 7. After backend selection: framework copy

**What happened:** `RecaptchaEnterprise` failed twice, including an unchanged
control. Logs: `stage-06-native-backend.log`, `stage-06b-unchanged-control.log`.

**Error:**

```text
error: <workspace>\scratch\arm64-apple-ios\debug\RecaptchaEnterpriseSDK.framework is not a directory
```

**Cause and fix:** The source was populated. Its copy input used `\\?\C:\...`;
Foundation's copy probe failed with that prefix and succeeded without it.
Normalize extended drive-qualified directory copy inputs in the Windows
build-description repair. PR commit: `802fc6f`. The real target then completed:

```text
Build of target: 'RecaptchaEnterprise' complete! (11.09s)
```

## 8. After framework copying: compiler command length

**What happened:** SwiftPM could not start the aggregate plugin compiler.
Log: `stage-07-directory-copy.log`.

**Error:**

```text
error: command Compiling Swift Module 'FlutterPluginsGenerated' (1 sources) failed: unable to spawn process '<toolchain>\swiftc.exe' (Der Dateiname oder die Erweiterung ist zu lang.
)
```

**Cause and fix:** The executable path was 90 characters. The 600 additional
arguments alone totaled 34,470 characters, exceeding Windows' 32,767-character
command-line limit. Use response files for oversized Swift compiler arguments,
preserving order and Windows quoting. PR commit: `a6d0a4d`.

The actual compiler invocation then passed with exit 0; its final launch command
was 243 characters. Local follow-up `6149791` guards the helper directly, in
addition to its Windows-only caller. Tests verify no file changes on the
simulated non-Windows path. Short calls and other tools remain unchanged.

## 9. Intermittent Foundation failure: no confirmed fix

**What happened:** A subsequent full run failed during the FirebaseAuth prebuild.
Log: `stage-08-response-files.log`.

**Error:**

```text
error: compile command failed due to exception 5 (use -v to see invocation)
<unknown>:0: error: module 'Foundation' is defined in both '<workspace>\scratch\arm64-apple-ios\debug\ModuleCache\MG6K5G75SYKX\Foundation-4VZ0EU7XM6N7.pcm' and '<workspace>\scratch\arm64-apple-ios\debug\ModuleCache\MG6K5G75SYKX\Foundation-4VZ0EU7XM6N7.pcm'
```

**Status:** Cause unconfirmed; no dedicated fix. The next guarded reproduction
build passed without a cache reset, and the full PR-branch build also passed.
Do not attribute this to the guard or claim a proven Foundation fix.

## 10. Full PR-branch verification

**What happened:** Rebuilt the PR bundle from `bd94046` and ran the same app build.
Log: `stage-10-pr-branch.log`. Later commits only change tests/documentation.

**Result — exit code 0:**

```text
Building Flutter plugins (Swift Package Manager) 8m22s
Compiling Runner                      1.1s
 Wrote <app>\build\xcross-ios\app.app
```

- 229 focused tests passed; analysis and formatting passed for 27 changed Dart files.
- The guard and final validation commits remain local, not pushed.
- The build retained the Sentry override and SDK/caches; this is not a clean
  build with unmodified dependencies.
- No new device-launch test or native Linux/macOS build was performed.

File-level rationale and historical device/runtime findings are in
[cross-host-flutter-fixes.md](cross-host-flutter-fixes.md). Those historical
findings are not new reproductions from the unchanged release.
