import 'dart:io';

import 'package:args/args.dart';

import 'ios_aot/snapshotter_builder.dart';
import 'ios_aot/snapshotter_context.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('repository')
    ..addOption('cache-root')
    ..addOption('clang-root')
    ..addOption('visual-studio')
    ..addOption('python', help: 'Python used by upstream GN/Dart scripts only')
    ..addOption('jobs', defaultsTo: '2')
    ..addOption('package-output')
    ..addFlag('configure-only', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
  final options = parser.parse(arguments);
  if (options.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  final context = SnapshotterContext(
    options.option('repository') ?? findSnapshotterRepository(),
    cacheRoot: options.option('cache-root'),
  );
  await SnapshotterBuilder(context).build(
    packageOutput: options.option('package-output'),
    clangRoot: options.option('clang-root'),
    visualStudio: options.option('visual-studio'),
    python: options.option('python'),
    jobs: int.parse(options.option('jobs')!),
    configureOnly: options.flag('configure-only'),
  );
}
