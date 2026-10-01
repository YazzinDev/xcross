import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross/src/flutter/build/internal/build_lock.dart';
import 'package:xcross/src/flutter/flutter.dart';

part 'flutter_build_command.g.dart';

/// Shared `flutter build`/`flutter run` options: entry-point target, flavor,
/// dart-defines, and `--pub`.
class CommonFlutterArgs {
  @CliOption(
    help: 'Obfuscate Dart names (requires --release and --split-debug-info).',
    negatable: false,
  )
  late bool obfuscate;

  @CliOption(
    help:
        'Directory for Dart stack trace symbols; keep this output for symbolication.',
  )
  late String? splitDebugInfo;

  @CliOption(help: 'Build a debug JIT app (default).', negatable: false)
  late bool debug;

  @CliOption(help: 'Build a release iOS ARM64 AOT app.', negatable: false)
  late bool release;

  @CliOption(help: 'Profile mode (currently unsupported).', negatable: false)
  late bool profile;

  @CliOption(
    abbr: 't',
    defaultsTo: 'lib/main.dart',
    help: 'The main entry-point file of the application.',
  )
  late String target;

  @CliOption(help: 'Build a custom app flavor (sets FLUTTER_APP_FLAVOR).')
  late String? flavor;

  @CliOption(abbr: 'D', help: 'Pass a KEY=VALUE define to the Dart compiler.')
  late List<String> dartDefine;

  @CliOption(help: 'Load dart-defines from a .json or .env file.')
  late List<String> dartDefineFromFile;

  @CliOption(help: 'Run "flutter pub get" before building.', defaultsTo: true)
  late bool pub;
}

/// Options for `xcross flutter build`.
@CliOptions(createCommand: true)
final class FlutterBuildArgs extends CommonFlutterArgs {
  @CliOption(help: 'Version name (CFBundleShortVersionString).')
  late String? buildName;

  @CliOption(help: 'Version code (CFBundleVersion).')
  late String? buildNumber;

  @CliOption(
    abbr: 'i',
    negatable: false,
    help: 'Output a .ipa file instead of a .app.',
  )
  late bool ipa;
}

/// `xcross flutter build` — build a Flutter iOS `.app` (optionally ipa).
///
/// `build` produces an unsigned bundle and signing
/// happens when `xcross flutter run` installs it.
final class FlutterBuildCommand extends _$FlutterBuildArgsCommand<void> {
  @override
  String get name => 'build';

  @override
  String get description => 'Build a Flutter iOS .app without Xcode.';

  @override
  Future<void> run() => withFlutterProjectLock(_runLocked);

  Future<void> _runLocked() async {
    final options = await FlutterBuildOptions.resolve(
      target: _options.target,
      obfuscate: _options.obfuscate,
      splitDebugInfo: _options.splitDebugInfo,
      dartDefine: _options.dartDefine,
      dartDefineFromFile: _options.dartDefineFromFile,
      pub: _options.pub,
      buildName: _options.buildName,
      buildNumber: _options.buildNumber,
      flavor: _options.flavor,
      mode: FlutterBuildMode.fromFlags(
        debug: _options.debug,
        release: _options.release,
        profile: _options.profile,
      ),
    );

    final result = await FlutterPackOperation.pack(options: options);

    final finalPath = _options.ipa
        ? await IpaPackager.package(result.appPath)
        : result.appPath;
    Log.logDone('Wrote $finalPath');
  }
}
