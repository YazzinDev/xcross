import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/app_extension_builder.dart';
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/flutter_notice_artifact.dart';
import 'package:xcross/src/flutter/build/flutter_release_bundler.dart';
import 'package:xcross/src/flutter/build/info_plist.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_linkage.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/internal/runner_binary.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/internal/xcconfig_resolver.dart';
import 'package:xcross/src/flutter/build/ios_app_extensions.dart';
import 'package:xcross/src/flutter/build/ios_bundle_resources.dart';
import 'package:xcross/src/flutter/build/ios_bundle_versions.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/build/ios_native_assets.dart';

import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/build/ios_plugins.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';
import 'package:xcross/src/package_config_resolver.dart';

/// Builds a Flutter iOS `.app` bundle using Dart and xcross's cross-platform
/// toolchain. Does NOT call `xcrun`.
///
/// Pipeline:
///   1. Resolve `FLUTTER_ROOT` and run `flutter pub get`.
///   2. Build `App.framework` via [FlutterDebugBundler] (JIT) or
///      [FlutterReleaseBundler] (product kernel + native iOS AOT cross-compiler).
///   3. Run Dart build hooks and package their native asset frameworks.
///   4. Discover iOS plugins and build the aggregate Swift Package Manager
///      plugins library via [GeneratedPluginsPackage], if any exist.
///   5. Compile the ObjC Runner shim via [RunnerShim], linking in the
///      plugins library when present.
///   6. Assemble the `.app` bundle and write `Info.plist`.
final class FlutterPacker {
  static String? _flutterRootOverride;
  static String? _flutterEnvironmentRoot;
  static String? _flutterToolOverride;
  static bool _declarative = false;

  /// Configures declarative Flutter resolution without coupling this layer to
  /// the application configuration types.
  static void configureFlutterResolution({
    required bool declarative,
    String? root,
    String? environmentRoot,
    String? tool,
  }) {
    _flutterRootOverride = root;
    _flutterEnvironmentRoot = environmentRoot;
    _flutterToolOverride = tool;
    _declarative = declarative;
  }

  /// Legacy root-only seam retained for embedders.
  static void configureFlutterRootOverride(String? root) {
    _flutterRootOverride = root;
  }

  /// Removes configured Flutter resolution.
  static void resetFlutterRootOverride() {
    _flutterRootOverride = null;
    _flutterEnvironmentRoot = null;
    _flutterToolOverride = null;
    _declarative = false;
  }

  final String projectRoot;
  final String bundleId;
  final FlutterBuildOptions options;
  bool get _release => options.mode == FlutterBuildMode.release;
  String get _modeSuffix => _release ? '-release' : '';
  final bool swiftPmArtifactJunctionCapability;
  final bool packageLocalArtifactJunctionCapability;
  final ArtifactJunctionCapabilityResolver? artifactJunctionCapabilityResolver;

  /// App name read from `pubspec.yaml` `name:` key.
  final String appName;

  FlutterPacker({
    required this.projectRoot,
    required this.bundleId,
    required this.options,
    this.swiftPmArtifactJunctionCapability = false,
    this.packageLocalArtifactJunctionCapability = false,
    this.artifactJunctionCapabilityResolver,
  }) : appName = PubspecInfo.loadSync(projectRoot).name,
       _versions = IosBundleVersions.resolve(
         projectRoot,
         buildName: options.buildName,
         buildNumber: options.buildNumber,
       );

  /// Versions the app and every embedded extension must agree on.
  final IosBundleVersions _versions;

  /// Build the Flutter iOS app.
  /// Returns path to `<projectRoot>/build/xcross-ios/<appName>.app`.
  Future<String> pack() async {
    final flutterRoot = await resolveFlutterRoot(projectRoot: projectRoot);
    Log.logTrace('Flutter SDK: $flutterRoot');

    if (options.pub) {
      await _runFlutterPubGet(flutterRoot);
    } else {
      Log.logTrace('skipping flutter pub get (--no-pub)');
    }

    if (options.flavor != null) {
      Log.logTrace('building flavor "${options.flavor}"');
    }

    final deploymentTarget = IosDeploymentTarget.resolve(projectRoot);
    Log.logTrace('iOS deployment target: ${deploymentTarget.version}');

    await validateIosResourceSources(projectRoot, strict: _release);

    if (_release) {
      validateReleasePlugins(await PluginDiscovery.discover(projectRoot));
      if (IosAppExtensions.discover(projectRoot).isNotEmpty) {
        throw FlutterBuildError(
          'Release app extensions have not been validated yet.',
        );
      }
    }

    return _withAppFramework(
      flutterRoot,
      deploymentTarget: deploymentTarget,
      consume: (appBuild) async {
        final appFramework = appBuild.framework;
        final nativeAssets = _release
            ? IosNativeAssetsBuildResult(
                manifestPath: p.join(
                  appFramework,
                  'flutter_assets',
                  'NativeAssetsManifest.json',
                ),
                frameworks: appBuild.nativeFrameworks,
              )
            : await Log.logStep(
                'Building native assets',
                () => IosNativeAssetsBuilder(
                  projectRoot: projectRoot,
                  flutterRoot: flutterRoot,
                  deploymentTarget: deploymentTarget,
                  entrypoint: options.target,
                  dartDefines: options.dartDefines,
                  flavor: options.flavor,
                ).build(),
              );
        if (!_release) {
          copyFlutterNoticeArtifact(
            sourceFlutterAssetsDirectory: p.dirname(nativeAssets.manifestPath),
            destinationFlutterAssetsDirectory: p.join(
              appFramework,
              'flutter_assets',
            ),
          );
          await File(nativeAssets.manifestPath).copy(
            p.join(appFramework, 'flutter_assets', 'NativeAssetsManifest.json'),
          );
        }
        final pluginsBuild = await _buildPlugins(
          flutterRoot,
          deploymentTarget: deploymentTarget,
          verbose: Log.isVerbose,
        );
        // Flutter normally opens native assets via the manifest. A SwiftPM dylib
        // can nevertheless import a symbol from one of those frameworks without
        // declaring a load command for it. Bridge only that proven dependency at
        // launch; do not eagerly load every embedded native asset.
        final requiredNativeFrameworks =
            await nativeFrameworksRequiredByPlugins(
              nativeAssets.frameworks,
              pluginsBuild?.dylibPaths ?? const [],
            );
        final runnerResult = await _buildRunnerBinary(
          flutterRoot,
          deploymentTarget: deploymentTarget,
          pluginsLibrary: pluginsBuild?.libraryPath,
          nativeAssetFrameworks: requiredNativeFrameworks,
          verbose: Log.isVerbose,
        );

        final extensions = await _buildAppExtensions(
          deploymentTarget: deploymentTarget,
          flutterXcframework: runnerResult.xcframework,
          pluginsBuild: pluginsBuild,
        );

        return _assembleAndPersistBundle(
          appFramework: appFramework,
          xcframework: runnerResult.xcframework,
          runnerBinary: runnerResult.runnerBinary,
          sdkName: runnerResult.sdkName,
          pluginLibraries: pluginsBuild?.dylibPaths ?? const [],
          pluginResourceBundles: pluginsBuild?.resourceBundles ?? const [],
          nativeAssetFrameworks: nativeAssets.frameworks,
          deploymentTarget: deploymentTarget,
          extensions: extensions,
        );
      },
    );
  }

  /// Resolve the Flutter SDK root using, in order:
  ///   1. Explicit [root], configured root, or configured `FLUTTER_ROOT`.
  ///   2. `<projectRoot>/.fvm/flutter_sdk` symlink (fvm).
  ///   3. Configured `tools.flutter`.
  ///
  /// Legacy mode additionally consults the platform environment and tool
  /// discovery (including mise compatibility).
  static Future<String> resolveFlutterRoot({
    required String projectRoot,
    String? root,
  }) async {
    final configuredRoot = root ?? _flutterRootOverride;
    if (configuredRoot != null && configuredRoot.isNotEmpty) {
      return configuredRoot;
    }
    final configuredEnvironmentRoot = _flutterEnvironmentRoot;
    if (configuredEnvironmentRoot != null &&
        configuredEnvironmentRoot.isNotEmpty) {
      return configuredEnvironmentRoot;
    }
    if (!_declarative) {
      final inheritedEnvironmentRoot = Platform.environment['FLUTTER_ROOT'];
      if (inheritedEnvironmentRoot != null &&
          inheritedEnvironmentRoot.isNotEmpty) {
        return inheritedEnvironmentRoot;
      }
    }

    final fvmLink = p.join(projectRoot, '.fvm', 'flutter_sdk');
    final fvmLinkExists =
        Directory(fvmLink).existsSync() || Link(fvmLink).existsSync();
    if (fvmLinkExists) {
      return Link(fvmLink).resolveSymbolicLinksSync();
    }

    final flutter = _flutterToolOverride;
    if (_declarative && (flutter == null || flutter.isEmpty)) {
      throw FlutterBuildError(
        'Flutter SDK not configured. Set roots.flutterSdk, environment '
        'FLUTTER_ROOT, tools.flutter, or add .fvm/flutter_sdk to the project.',
      );
    }
    final locatedFlutter = flutter ?? await ProcessRunner.locateTool('flutter');
    final resolved = _declarative && flutter != null
        ? locatedFlutter
        : File(locatedFlutter).resolveSymbolicLinksSync();
    if (!_declarative &&
        Platform.isWindows &&
        p.basename(p.dirname(resolved)) == 'shims') {
      final result = await ProcessRunner.run(
        await ProcessRunner.locateTool('mise'),
        ['where', 'flutter'],
      );
      if (result.exitCode == 0) {
        final miseRoot = result.stdout.trim();
        if (Directory(p.join(miseRoot, 'bin')).existsSync()) return miseRoot;
      }
    }
    // The `flutter` script lives at <root>/bin/flutter.
    return p.dirname(p.dirname(resolved));
  }

  /// Run `flutter pub get`. Tolerates failures when `package_config.json`
  /// already exists (container builds with ephemeral pub caches).
  Future<void> _runFlutterPubGet(String flutterRoot) {
    return Log.logStep('Resolving dependencies', () async {
      try {
        await ProcessRunner.runChecked(
          p.join(
            flutterRoot,
            'bin',
            ProcessRunner.hostExecutableName(
              'flutter',
              windowsExtension: '.bat',
            ),
          ),
          ['pub', 'get'],
          workingDirectory: projectRoot,
          // `pub get` is non-interactive; inheriting fd1 would shred the
          // spinner, so only inherit when verbose (no spinner then).
          inheritStdio: Log.isVerbose,
          label: 'flutter',
        );
      } on FlutterBuildError {
        final packageConfig = await PackageConfigResolver.find(projectRoot);
        final packageConfigExists = packageConfig != null;
        if (packageConfigExists) {
          Log.logWarn(
            'Ignoring flutter pub get error because '
            'package_config.json exists.',
          );
          return;
        }
        rethrow;
      }
    });
  }

  /// Build `App.framework` with the mode's dedicated compiler pipeline.
  /// Keep release intermediates alive until the consumer finishes packaging.
  Future<T> _withAppFramework<T>(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
    required Future<T> Function(
      ({String framework, List<String> nativeFrameworks}),
    )
    consume,
  }) async {
    if (_release) {
      return FlutterReleaseBundler(
        projectRoot: projectRoot,
        flutterRoot: flutterRoot,
        outputDir: p.join(projectRoot, 'build', 'xcross-flutter-release'),
        deploymentTarget: deploymentTarget,
        options: options,
      ).build(consume);
    }
    final assembleOut = p.join(projectRoot, 'build', 'xcross-flutter-debug');
    final assembleDir = Directory(assembleOut);
    if (assembleDir.existsSync()) await assembleDir.delete(recursive: true);
    await assembleDir.create(recursive: true);

    final framework = await FlutterDebugBundler(
      projectRoot: projectRoot,
      flutterRoot: flutterRoot,
      outputDir: assembleOut,
      deploymentTarget: deploymentTarget,
      entrypoint: options.target,
      dartDefines: options.dartDefines,
      flavor: options.flavor,
    ).build();
    return consume((framework: framework, nativeFrameworks: const <String>[]));
  }

  /// Discover the project's iOS plugins and build the aggregate Swift
  /// Package Manager plugins library, if any exist.
  ///
  /// Returns the built dylibs, or null when there's nothing to build — no
  /// plugins at all, or only CocoaPods-only ones xcross doesn't support (a
  /// warning is logged for those; matching Flutter's own tool, this doesn't
  /// fail a debug build). Release rejects unsupported native plugins up front.
  Future<GeneratedPluginsBuildResult?> _buildPlugins(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
  }) async {
    final plugins = await PluginDiscovery.discover(projectRoot);
    final spmPlugins = <IosPlugin>[];
    for (final plugin in plugins) {
      final dir = plugin.platformDirectoryName;
      if (plugin.usesSwiftPackageManager) {
        spmPlugins.add(plugin);
      } else if (plugin.usesCocoaPods) {
        Log.logWarn(
          'Plugin "${plugin.name}" only ships a CocoaPods podspec '
          '(no $dir/${plugin.name}/Package.swift); its native iOS code will '
          'not be included. xcross only supports Swift Package Manager '
          'plugins.',
        );
      } else if (plugin.declaresNativeIosCode) {
        // The plugin's pubspec claims a native iOS pluginClass, but neither a
        // Package.swift nor a podspec turned up where they were looked for.
        // Staying silent here is what made a dropped plugin present as a black
        // screen: the app launches, then the first method channel call to the
        // missing implementation never returns.
        Log.logWarn(
          'Plugin "${plugin.name}" declares native iOS code but no '
          '$dir/${plugin.name}/Package.swift or $dir/${plugin.name}.podspec '
          'was found under ${plugin.packageRoot}; its plugin channels will '
          'not respond at runtime.',
        );
      }
    }
    if (spmPlugins.isEmpty) return null;

    final xcframework = IosEngineCache(
      flutterRoot: flutterRoot,
      mode: options.mode,
    ).flutterXcframework;
    final capabilities =
        await artifactJunctionCapabilityResolver?.call() ??
        (
          swiftPmArtifact: swiftPmArtifactJunctionCapability,
          packageLocalArtifact: packageLocalArtifactJunctionCapability,
        );

    final workspace = SwiftPmWorkspace.forProject(
      projectRoot,
      mode: options.mode,
    );
    return GeneratedPluginsPackage.build(
      mode: options.mode,
      projectRoot: projectRoot,
      workspace: workspace,
      plugins: spmPlugins,
      flutterXcframework: xcframework,
      deploymentTarget: deploymentTarget,
      verbose: verbose,
      swiftPmArtifactJunctionCapability: capabilities.swiftPmArtifact,
      packageLocalArtifactJunctionCapability: capabilities.packageLocalArtifact,
    );
  }

  /// Refuse incomplete release bundles before running any compiler.
  @visibleForTesting
  static void validateReleasePlugins(Iterable<IosPlugin> plugins) {
    for (final plugin in plugins) {
      if (!plugin.usesSwiftPackageManager &&
          (plugin.usesCocoaPods || plugin.declaresNativeIosCode)) {
        throw FlutterBuildError(
          'Release plugin "${plugin.name}" requires '
          '${plugin.platformDirectoryName}/${plugin.name}/Package.swift. '
          'CocoaPods-only or missing native packages are not supported.',
        );
      }
    }
  }

  /// Build the project's iOS app extensions (share/action extensions), if any.
  ///
  /// Extensions whose bundle id is not nested under the host app's are
  /// skipped with a warning: iOS refuses to install those, and dropping one
  /// is better than failing an otherwise valid app build.
  Future<List<BuiltAppExtension>> _buildAppExtensions({
    required IosDeploymentTarget deploymentTarget,
    required String flutterXcframework,
    GeneratedPluginsBuildResult? pluginsBuild,
  }) async {
    final discovered = IosAppExtensions.discover(projectRoot);
    if (discovered.isEmpty) return const [];

    final buildable = <IosAppExtension>[];
    for (final extension in discovered) {
      if (extension.suffixUnder(bundleId) == null) {
        Log.logWarn(
          'Skipping app extension "${extension.name}": its bundle id '
          '${extension.bundleId} is not nested under the app id $bundleId.',
        );
        continue;
      }
      buildable.add(extension);
    }

    return AppExtensionBuilder.buildAll(
      projectRoot: projectRoot,
      extensions: buildable,
      deploymentTarget: deploymentTarget,
      outputDir: p.join(
        projectRoot,
        'build',
        'xcross-flutter-extensions$_modeSuffix',
      ),
      versions: _versions,
      flutterXcframework: flutterXcframework,
      pluginsLibrary: pluginsBuild?.libraryPath,
      pluginModulesDir: pluginsBuild?.modulesDir,
    );
  }

  /// Compile the ObjC Runner shim and return both the xcframework path and the
  /// linked Runner binary path.
  Future<RunnerBinary> _buildRunnerBinary(
    String flutterRoot, {
    required IosDeploymentTarget deploymentTarget,
    required bool verbose,
    String? pluginsLibrary,
    List<String> nativeAssetFrameworks = const [],
  }) async {
    final xcframework = IosEngineCache(
      flutterRoot: flutterRoot,
      mode: options.mode,
    ).flutterXcframework;

    final darwin = DarwinSdk.current();
    if (darwin == null) {
      throw FlutterBuildError(
        'FlutterPacker: Darwin SDK not found. '
        'Install with `xcross sdk install <Xcode.xip|Xcode.app>`.',
      );
    }

    final runnerBinary = await RunnerShim.buildRunnerBinary(
      projectRoot: projectRoot,
      sdk: darwin,
      flutterXcframework: xcframework,
      outputDir: p.join(
        projectRoot,
        'build',
        'xcross-flutter-runner-bin$_modeSuffix',
      ),
      deploymentTarget: deploymentTarget,
      pluginsLibrary: pluginsLibrary,
      nativeAssetFrameworks: nativeAssetFrameworks,
      verbose: verbose,
    );

    return RunnerBinary(
      xcframework: xcframework,
      runnerBinary: runnerBinary,
      sdkName: p.basenameWithoutExtension(darwin.iPhoneOSSdk()).toLowerCase(),
    );
  }

  /// Stage the bundle in a temp directory, then move it to
  /// `build/xcross-ios/<appName>.app`.
  Future<String> _assembleAndPersistBundle({
    required String appFramework,
    required String xcframework,
    required String runnerBinary,
    required String sdkName,
    required List<String> pluginLibraries,
    required List<String> pluginResourceBundles,
    required List<String> nativeAssetFrameworks,
    required IosDeploymentTarget deploymentTarget,
    required List<BuiltAppExtension> extensions,
  }) async {
    final parent = Directory(
      p.join(projectRoot, 'build', options.mode.bundleDirectory),
    );
    await parent.create(recursive: true);
    final tmp = await parent.createTemp('.$appName-stage-');
    final dest = p.join(parent.path, '$appName.app');
    final backup = '${tmp.path}.previous';
    var preserved = false;
    try {
      await _stageBundle(
        bundleDir: tmp.path,
        appFramework: appFramework,
        flutterFramework: p.join(xcframework, 'ios-arm64', 'Flutter.framework'),
        runnerBinary: runnerBinary,
        sdkName: sdkName,
        pluginLibraries: pluginLibraries,
        pluginResourceBundles: pluginResourceBundles,
        nativeAssetFrameworks: nativeAssetFrameworks,
        deploymentTarget: deploymentTarget,
        extensions: extensions,
      );
      if (Directory(dest).existsSync()) {
        await Directory(dest).rename(backup);
        preserved = true;
      }
      try {
        await tmp.rename(dest);
      } on Object {
        if (preserved) await Directory(backup).rename(dest);
        rethrow;
      }
      if (preserved) await Directory(backup).delete(recursive: true);
    } finally {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    }

    return dest;
  }

  /// Lay out the `.app` contents under [bundleDir]: the Runner executable,
  /// the embedded frameworks and plugin dylibs, storyboards, and `Info.plist`.
  Future<void> _stageBundle({
    required String bundleDir,
    required String appFramework,
    required String flutterFramework,
    required String runnerBinary,
    required String sdkName,
    required List<String> pluginLibraries,
    required List<String> pluginResourceBundles,
    required List<String> nativeAssetFrameworks,
    required IosDeploymentTarget deploymentTarget,
    required List<BuiltAppExtension> extensions,
  }) async {
    final frameworksDir = p.join(bundleDir, 'Frameworks');
    await Directory(frameworksDir).create(recursive: true);

    final runnerDest = p.join(bundleDir, 'Runner');
    await File(runnerBinary).copy(runnerDest);
    ProcessRunner.makeExecutable(runnerDest);

    await copyDirectoryPreservingSymlinks(
      flutterFramework,
      p.join(frameworksDir, 'Flutter.framework'),
    );
    await copyDirectoryPreservingSymlinks(
      appFramework,
      p.join(frameworksDir, 'App.framework'),
    );
    await copyPluginLibraries(pluginLibraries, frameworksDir);
    for (final resource in pluginResourceBundles) {
      final destination = p.join(bundleDir, p.basename(resource));
      if (FileSystemEntity.typeSync(destination) !=
          FileSystemEntityType.notFound) {
        throw FlutterBuildError(
          'Duplicate plugin resource bundle: $destination',
        );
      }
      await copyDirectoryPreservingSymlinks(resource, destination);
    }
    await copyNativeAssetFrameworks(nativeAssetFrameworks, frameworksDir);

    await _embedAppExtensions(bundleDir, extensions);
    final assetPlist = await stageIosBundleResources(
      projectRoot: projectRoot,
      bundleDir: bundleDir,
      strict: _release,
      compileSources: _release,
      deploymentTarget: deploymentTarget.version,
    );
    await _writeInfoPlist(
      bundleDir,
      assetPlist: assetPlist,
      deploymentTarget: deploymentTarget,
      sdkName: sdkName,
    );
  }

  /// Copy each built `.appex` into the app's `PlugIns` directory, the only
  /// location iOS looks for embedded app extensions.
  static Future<void> _embedAppExtensions(
    String bundleDir,
    List<BuiltAppExtension> extensions,
  ) async {
    if (extensions.isEmpty) return;
    final plugInsDir = p.join(bundleDir, 'PlugIns');
    await Directory(plugInsDir).create(recursive: true);
    for (final extension in extensions) {
      await copyDirectoryPreservingSymlinks(
        extension.bundlePath,
        p.join(plugInsDir, extension.extension.bundleName),
      );
    }
  }

  /// Copies every SwiftPM-produced dylib into the app's Frameworks directory.
  @visibleForTesting
  static Future<void> copyPluginLibraries(
    Iterable<String> pluginLibraries,
    String frameworksDir,
  ) async {
    for (final library in pluginLibraries) {
      await File(library).copy(p.join(frameworksDir, p.basename(library)));
    }
  }

  /// Copies every native-asset framework into the app's Frameworks directory.
  @visibleForTesting
  static Future<void> copyNativeAssetFrameworks(
    Iterable<String> frameworks,
    String frameworksDir,
  ) async {
    for (final framework in frameworks) {
      await copyDirectoryPreservingSymlinks(
        framework,
        p.join(frameworksDir, p.basename(framework)),
      );
    }
  }

  /// Generate and write `Info.plist` into [bundleDir] with `$(VAR)`
  /// substitution, mandatory iOS keys, storyboard validation, and ObjC class
  /// name normalization.
  Future<void> _writeInfoPlist(
    String bundleDir, {
    required IosDeploymentTarget deploymentTarget,
    required String sdkName,
    String? assetPlist,
  }) async {
    var plistXml = await _loadPlistTemplate();

    // ORDER MATTERS: vars must be expanded before forcing keys so that forced
    // keys see already-substituted values from the template, and before
    // storyboard validation so $(VAR)-valued storyboard names are resolved
    // before the .storyboardc filesystem probe.
    plistXml = InfoPlist.expandXmlVars(
      plistXml,
      await buildSubstitutionMap(sdkName: sdkName),
    );
    plistXml = InfoPlist.applyIosRequiredKeys(
      plistXml,
      bundleId: bundleId,
      deploymentTarget: deploymentTarget,
    );
    if (!_release) plistXml = InfoPlist.applyDebugVmServiceDiscovery(plistXml);
    if (assetPlist != null) {
      plistXml = InfoPlist.mergeAssetMetadata(plistXml, assetPlist);
    }
    if (_release) {
      InfoPlist.validateStoryboardReferences(plistXml, bundleDir);
    } else {
      plistXml = InfoPlist.stripUnsatisfiableStoryboards(plistXml, bundleDir);
    }
    plistXml = InfoPlist.applySceneLifecycle(plistXml);
    plistXml = InfoPlist.normalizeObjCClassNames(plistXml);
    // Carry the app's own App Groups forward so the sign/install stage can
    // provision them alongside its extensions'.
    plistXml = AppExtensionPlist.setAppGroups(plistXml, _hostAppGroups());

    await File(p.join(bundleDir, 'Info.plist')).writeAsString(plistXml);
  }

  /// App Groups declared by the application target's entitlements file.
  List<String> _hostAppGroups() {
    final extensionGroups = IosAppExtensions.applicationEntitlements(
      projectRoot,
    );
    return IosAppExtensions.readAppGroups(extensionGroups);
  }

  /// Read `ios/Runner/Info.plist`, falling back to [InfoPlist.fallback].
  Future<String> _loadPlistTemplate() async {
    final plistFile = File(p.join(projectRoot, 'ios', 'Runner', 'Info.plist'));
    if (plistFile.existsSync()) return plistFile.readAsString();
    return InfoPlist.fallback;
  }

  /// Build the `$(VAR)` substitution map.
  ///
  /// Precedence (lowest → highest):
  ///   1. Hard-coded defaults (`1.0.0` / `1`).
  ///   2. The build mode's `.xcconfig` and includes in textual order, falling back
  ///      to `Generated.xcconfig` only when no mode-specific file exists.
  ///   3. Explicit `--build-name` / `--build-number` CLI flags.
  @visibleForTesting
  Future<Map<String, String>> buildSubstitutionMap({
    String sdkName = 'iphoneos',
  }) async {
    final subs = <String, String>{
      'EXECUTABLE_NAME': PlistDefaults.executable,
      'PRODUCT_NAME': PlistDefaults.executable,
      'PRODUCT_MODULE_NAME': PlistDefaults.executable,
      'PRODUCT_BUNDLE_IDENTIFIER': bundleId,
      'DEVELOPMENT_LANGUAGE': 'en',
      'FLUTTER_BUILD_NAME': PlistDefaults.shortVersion,
      'FLUTTER_BUILD_NUMBER': PlistDefaults.bundleVersion,
      // Xcode expands these from the application target's build settings.
      // Without them, `ios/Runner/Info.plist` (which references them by
      // default) ships a literal "$(MARKETING_VERSION)" as the app version.
      'MARKETING_VERSION': _versions.shortVersion,
      'CURRENT_PROJECT_VERSION': _versions.bundleVersion,
    };

    // `receive_sharing_intent` and friends point the app's `AppGroupId` key
    // at `$(CUSTOM_GROUP_ID)`, which Xcode expands from the target's build
    // settings. The extension build already substitutes it; doing the same
    // here keeps both sides naming one container, instead of the app reading
    // back the literal `$(CUSTOM_GROUP_ID)` and finding nothing shared.
    final hostGroups = _hostAppGroups();
    if (hostGroups.isNotEmpty) {
      subs['CUSTOM_GROUP_ID'] = hostGroups.first;
    }

    final flutterConfigDirectory = p.join(projectRoot, 'ios', 'Flutter');
    final overrides = _buildVersionOverrides();
    subs.addAll(
      await XcconfigResolver.readDebugConfiguration(
        debugPath: p.join(
          flutterConfigDirectory,
          _release ? 'Release.xcconfig' : 'Debug.xcconfig',
        ),
        generatedPath: p.join(flutterConfigDirectory, 'Generated.xcconfig'),
        sdk: sdkName,
        defaults: subs,
        overrides: overrides,
      ),
    );
    subs.addAll(overrides);

    return subs;
  }

  /// Settings pinned by explicit `--build-name` / `--build-number` flags.
  Map<String, String> _buildVersionOverrides() => {
    if (options.buildName case final String name) ...{
      'FLUTTER_BUILD_NAME': name,
      'MARKETING_VERSION': name,
    },
    if (options.buildNumber case final String number) ...{
      'FLUTTER_BUILD_NUMBER': number,
      'CURRENT_PROJECT_VERSION': number,
    },
  };
}
