import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/ios_dsym.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';

import 'ios_aot/snapshotter_context.dart';

/// Cross-build a release SwiftPM plugin and its dynamic/resource dependency.
/// Requires the host's Swift/LLVM tools and an installed private Darwin SDK.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Expected the Flutter SDK path');
  }
  final repository = findSnapshotterRepository();
  final project = p.join(repository, 'tool', 'ios_aot', 'plugins_fixture');
  final engine = IosEngineCache(
    flutterRoot: p.absolute(arguments.single),
    mode: FlutterBuildMode.release,
  );
  await engine.ensureArtifactsAvailable();
  final result = await GeneratedPluginsPackage.build(
    projectRoot: project,
    workspace: SwiftPmWorkspace.forProject(
      project,
      mode: FlutterBuildMode.release,
    ),
    plugins: [
      IosPlugin(
        name: 'xcross_swift_probe',
        packageRoot: p.join(repository, 'tool', 'ios_aot', 'swift_plugin'),
      ),
    ],
    flutterXcframework: engine.flutterXcframework,
    deploymentTarget: IosDeploymentTarget.resolve(project),
    mode: FlutterBuildMode.release,
  );
  if (result == null) throw StateError('Release plugin was not built');
  final names = result.dylibPaths.map(p.basename).toSet();
  if (!names.containsAll([
    'libFlutterPluginsGenerated.dylib',
    'libProbeSupport.dylib',
  ])) {
    throw StateError('Missing aggregate or transitive release dylib: $names');
  }
  if (!result.resourceBundles.any(
    (bundle) => File(p.join(bundle, 'marker.txt')).existsSync(),
  )) {
    throw StateError('Missing transitive plugin resource bundle');
  }
  for (final binary in result.dylibPaths) {
    final uuid = await verifyIosDsym(binary, '$binary.dSYM');
    stdout.writeln('Verified release ${p.basename(binary)} and dSYM: $uuid');
  }

  // Exercise discovery's failure paths using copies, leaving the built cache intact.
  final temporary = await Directory.systemTemp.createTemp(
    'release-plugin-dsym-',
  );
  try {
    final aggregate = p.join(temporary.path, p.basename(result.libraryPath));
    await File(result.libraryPath).copy(aggregate);
    await _expectRejected(temporary.path, 'missing dSYM');
    final dependency = result.dylibPaths.firstWhere(
      (binary) => p.basename(binary) == 'libProbeSupport.dylib',
    );
    await copyDirectoryPreservingSymlinks(
      '$dependency.dSYM',
      '$aggregate.dSYM',
    );
    await _expectRejected(temporary.path, 'mismatched dSYM');
  } finally {
    await temporary.delete(recursive: true);
  }
  stdout.writeln(
    'Release plugin cross-build and dSYM rejection checks passed.',
  );
}

Future<void> _expectRejected(String output, String description) async {
  try {
    // This native integration check exercises the same seam as the unit tests.
    // ignore: invalid_use_of_visible_for_testing_member
    await GeneratedPluginsPackage.discoverAndRewriteDylibs(
      output,
      mode: FlutterBuildMode.release,
    );
  } on ProcessException {
    return;
  } on CliError {
    return;
  } on FlutterBuildError {
    return;
  }
  throw StateError('Release plugin discovery accepted $description');
}
