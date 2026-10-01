/// A version-bound adapter executed with the selected Flutter SDK's Dart and
/// flutter_tools package resolution. It imports SDK code without modifying it.
/// Kept as source so a compiled xcross executable can materialize a private copy.
const flutterReleaseAdapterSource = r'''
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/targets/assets.dart';
import 'package:flutter_tools/src/build_system/targets/common.dart';
import 'package:flutter_tools/src/build_system/targets/dart_plugin_registrant.dart';
import 'package:flutter_tools/src/build_system/targets/native_assets.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/context_runner.dart';
import 'package:flutter_tools/src/devfs.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:unified_analytics/unified_analytics.dart';

class XcrossReleaseAssets extends Target {
  const XcrossReleaseAssets();

  @override
  String get name => 'xcross_release_assets';
  @override
  List<Source> get inputs => const [];
  @override
  List<Source> get outputs => const [
    Source.pattern('{OUTPUT_DIR}/app.dill'),
    Source.pattern('{OUTPUT_DIR}/flutter_assets/NativeAssetsManifest.json'),
  ];
  @override
  List<String> get depfiles => const ['flutter_assets.d'];
  @override
  List<Target> get dependencies => const [KernelSnapshot(), InstallCodeAssets()];

  @override
  Future<void> build(Environment environment) async {
    final hooks = await LinkHooks.loadHookResult(environment);
    final depfile = await copyAssets(
      environment,
      environment.outputDir.childDirectory('flutter_assets'),
      dartHookResult: hooks,
      targetPlatform: TargetPlatform.ios,
      buildMode: BuildMode.release,
      flavor: environment.defines[kFlavor],
      additionalContent: {
        'NativeAssetsManifest.json': DevFSFileContent(
          environment.buildDir.childFile(InstallCodeAssets.nativeAssetsFilename),
        ),
      },
    );
    environment.depFileService.writeToFile(
      depfile, environment.buildDir.childFile('flutter_assets.d'),
    );
    environment.buildDir.childFile('app.dill').copySync(
      environment.outputDir.childFile('app.dill').path,
    );
  }
}

Future<void> main(List<String> arguments) async {
  final request = jsonDecode(io.File(arguments.single).readAsStringSync()) as Map<String, dynamic>;
  Cache.flutterRoot = request['flutterRoot'] as String;
  await runInContext(() async {
    final output = globals.fs.directory(request['output']);
    output.createSync(recursive: true);
    final environment = Environment(
      projectDir: globals.fs.directory(request['projectRoot']),
      packageConfigPath: request['packageConfig'] as String,
      outputDir: output,
      buildDir: output.childDirectory('intermediates'),
      cacheDir: output.childDirectory('cache'),
      flutterRootDir: globals.fs.directory(Cache.flutterRoot),
      fileSystem: globals.fs,
      logger: globals.logger,
      artifacts: OverrideArtifacts(
        parent: globals.artifacts!,
        flutterPatchedSdk: globals.fs.file(request['patchedSdk']),
        platformKernelDill: globals.fs.directory(request['patchedSdk']).childFile('platform_strong.dill'),
      ),
      processManager: globals.processManager,
      platform: globals.platform,
      analytics: const NoOpAnalytics(),
      engineVersion: request['engineHash'] as String,
      generateDartPluginRegistry: true,
      defines: Map<String, String>.from(request['defines'] as Map),
    );
    // Flutter generates the registry under the project, but KernelCompiler
    // discovers it relative to buildDir.parent. Our isolated intermediates
    // deliberately live elsewhere. Bridge those paths before running the
    // upstream graph so the engine's AOT entry-point registry is included.
    await const DartPluginRegistrantTarget().build(environment);
    final generatedRegistry = FlutterProject.fromDirectory(environment.projectDir)
        .dartPluginRegistrant;
    final compilerRegistry = environment.buildDir.parent
        .childFile('dart_plugin_registrant.dart');
    if (generatedRegistry.existsSync()) {
      compilerRegistry.parent.createSync(recursive: true);
      generatedRegistry.copySync(compilerRegistry.path);
    } else if (compilerRegistry.existsSync()) {
      compilerRegistry.deleteSync();
    }
    final result = await globals.buildSystem.build(const XcrossReleaseAssets(), environment);
    if (!result.success) {
      for (final failure in result.exceptions.values) {
        globals.printError('${failure.target}: ${failure.exception}');
      }
      throwToolExit('Flutter release kernel/assets failed');
    }
    output.childFile('adapter-result.json').writeAsStringSync(jsonEncode({
      'kernel': output.childFile('app.dill').path,
      'assets': output.childDirectory('flutter_assets').path,
      'buildDirectory': environment.buildDir.path,
    }));
  }, overrides: {
    Analytics: () => const NoOpAnalytics(),
    TemplateRenderer: () => const MustacheTemplateRenderer(),
  });
}
''';
