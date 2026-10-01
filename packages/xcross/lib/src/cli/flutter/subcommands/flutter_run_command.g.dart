// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flutter_run_command.dart';

// **************************************************************************
// CliGenerator
// **************************************************************************

T _$enumValueHelper<T>(Map<T, String> enumValues, String source) => enumValues
    .entries
    .singleWhere(
      (e) => e.value == source,
      orElse: () => throw ArgumentError(
        '`$source` is not one of the supported values: '
        '${enumValues.values.join(', ')}',
      ),
    )
    .key;

FlutterRunArgs _$parseFlutterRunArgsResult(ArgResults result) =>
    FlutterRunArgs()
      ..obfuscate = result['obfuscate'] as bool
      ..splitDebugInfo = result['split-debug-info'] as String?
      ..debug = result['debug'] as bool
      ..release = result['release'] as bool
      ..profile = result['profile'] as bool
      ..target = result['target'] as String
      ..flavor = result['flavor'] as String?
      ..dartDefine = result['dart-define'] as List<String>
      ..dartDefineFromFile = result['dart-define-from-file'] as List<String>
      ..pub = result['pub'] as bool
      ..deviceId = result['device-id'] as String?
      ..udid = result['udid'] as String?
      ..usb = result['usb'] as bool
      ..wifi = result['wifi'] as bool
      ..deviceConnection = _$enumValueHelper(
        _$DeviceConnectionEnumMapBuildCli,
        result['device-connection'] as String,
      )
      ..route = result['route'] as String?
      ..dartEntrypointArgs = result['dart-entrypoint-args'] as List<String>
      ..verbose = result['verbose'] as bool;

const _$DeviceConnectionEnumMapBuildCli = <DeviceConnection, String>{
  DeviceConnection.attached: 'attached',
  DeviceConnection.wireless: 'wireless',
  DeviceConnection.both: 'both',
};

ArgParser _$populateFlutterRunArgsParser(ArgParser parser) => parser
  ..addFlag(
    'obfuscate',
    help: 'Obfuscate Dart names (requires --release and --split-debug-info).',
    negatable: false,
  )
  ..addOption(
    'split-debug-info',
    help:
        'Directory for Dart stack trace symbols; keep this output for symbolication.',
  )
  ..addFlag('debug', help: 'Build a debug JIT app (default).', negatable: false)
  ..addFlag(
    'release',
    help: 'Build a release iOS ARM64 AOT app.',
    negatable: false,
  )
  ..addFlag(
    'profile',
    help: 'Profile mode (currently unsupported).',
    negatable: false,
  )
  ..addOption(
    'target',
    abbr: 't',
    help: 'The main entry-point file of the application.',
    defaultsTo: 'lib/main.dart',
  )
  ..addOption(
    'flavor',
    help: 'Build a custom app flavor (sets FLUTTER_APP_FLAVOR).',
  )
  ..addMultiOption(
    'dart-define',
    abbr: 'D',
    help: 'Pass a KEY=VALUE define to the Dart compiler.',
  )
  ..addMultiOption(
    'dart-define-from-file',
    help: 'Load dart-defines from a .json or .env file.',
  )
  ..addFlag(
    'pub',
    help: 'Run "flutter pub get" before building.',
    defaultsTo: true,
  )
  ..addOption(
    'device-id',
    abbr: 'd',
    help: 'Target device id or name (flutter-style).',
  )
  ..addOption('udid', abbr: 'u', help: 'Target device UDID.')
  ..addFlag('usb', help: 'Search USB devices only.', negatable: false)
  ..addFlag('wifi', help: 'Search Wi-Fi devices only.', negatable: false)
  ..addOption(
    'device-connection',
    help: 'Discovery: attached (USB), wireless (Wi-Fi), or both.',
    defaultsTo: 'both',
    allowed: ['attached', 'wireless', 'both'],
  )
  ..addOption('route', help: 'Initial route the app navigates to on launch.')
  ..addMultiOption(
    'dart-entrypoint-args',
    abbr: 'a',
    help: 'Pass arguments to the app main() (repeatable).',
  )
  ..addFlag('verbose', abbr: 'v', help: 'Verbose output.', negatable: false);

final _$parserForFlutterRunArgs = _$populateFlutterRunArgsParser(ArgParser());

FlutterRunArgs parseFlutterRunArgs(List<String> args) {
  final result = _$parserForFlutterRunArgs.parse(args);
  return _$parseFlutterRunArgsResult(result);
}

abstract class _$FlutterRunArgsCommand<T> extends Command<T> {
  _$FlutterRunArgsCommand() {
    _$populateFlutterRunArgsParser(argParser);
  }

  late final _options = _$parseFlutterRunArgsResult(argResults!);
}
