import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/dart_defines.dart';

enum FlutterBuildMode {
  debug,
  release;

  String get bundleDirectory =>
      this == debug ? 'xcross-ios' : 'xcross-ios-release';

  static FlutterBuildMode fromFlags({
    bool debug = false,
    bool release = false,
    bool profile = false,
  }) {
    if ([debug, release, profile].where((value) => value).length > 1) {
      throw FlutterBuildError(
        'Choose only one of --debug, --release, or --profile.',
      );
    }
    if (profile) {
      throw FlutterBuildError(
        'iOS profile mode has not been validated and is not supported.',
      );
    }
    return release ? FlutterBuildMode.release : FlutterBuildMode.debug;
  }
}

/// Options shared by `xcross flutter build` and `run`, mirroring the semantics
/// of the official `flutter build ios` / `flutter run` arguments.
///
/// Debug uses JIT; release uses the separately validated iOS AOT toolchain.
final class FlutterBuildOptions {
  const FlutterBuildOptions({
    this.target = 'lib/main.dart',
    this.dartDefines = const [],
    this.pub = true,
    this.buildName,
    this.buildNumber,
    this.flavor,
    this.mode = FlutterBuildMode.debug,
    this.obfuscate = false,
    this.splitDebugInfo,
  });

  /// Build options from raw CLI arguments, merging `--dart-define-from-file`
  /// entries (lower precedence) with explicit `--dart-define` entries.
  static Future<FlutterBuildOptions> resolve({
    required String target,
    required List<String> dartDefine,
    required List<String> dartDefineFromFile,
    required bool pub,
    String? buildName,
    String? buildNumber,
    String? flavor,
    FlutterBuildMode mode = FlutterBuildMode.debug,
    bool obfuscate = false,
    String? splitDebugInfo,
  }) async {
    if (mode != FlutterBuildMode.release &&
        (obfuscate || splitDebugInfo != null)) {
      throw FlutterBuildError(
        'Obfuscation and split debug info require --release.',
      );
    }
    if ((obfuscate && splitDebugInfo == null) || splitDebugInfo == '') {
      throw FlutterBuildError(
        '--obfuscate requires a nonempty --split-debug-info directory.',
      );
    }
    return FlutterBuildOptions(
      target: target,
      dartDefines: await DartDefines.mergeDartDefines(
        dartDefineFromFile,
        dartDefine,
      ),
      pub: pub,
      buildName: buildName,
      buildNumber: buildNumber,
      flavor: flavor,
      mode: mode,
      obfuscate: obfuscate,
      splitDebugInfo: splitDebugInfo,
    );
  }

  /// `-t/--target` entrypoint.
  final String target;

  final FlutterBuildMode mode;
  final bool obfuscate;
  final String? splitDebugInfo;

  /// Merged `--dart-define` + `--dart-define-from-file` values as `KEY=VALUE`
  /// strings (file entries first, explicit `--dart-define` overriding them).
  final List<String> dartDefines;

  /// `--[no-]pub` — whether to run `flutter pub get`.
  final bool pub;

  /// `--build-name` → `CFBundleShortVersionString` (defaults to 1.0.0).
  final String? buildName;

  /// `--build-number` → `CFBundleVersion` (defaults to 1).
  final String? buildNumber;

  /// `--flavor` — sets the `FLUTTER_APP_FLAVOR` dart-define, readable at
  /// runtime via `appFlavor` from `package:flutter/services`.
  final String? flavor;
}
