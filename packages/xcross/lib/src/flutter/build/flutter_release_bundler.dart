import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/flutter_debug_bundler.dart';
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/flutter/build/internal/build_lock.dart';
import 'package:xcross/src/flutter/build/internal/dart_symbol_compatibility.dart';
import 'package:xcross/src/flutter/build/internal/flutter_release_adapter_source.dart';
import 'package:xcross/src/flutter/build/internal/ios_aot_artifact.dart';
import 'package:xcross/src/flutter/build/internal/ios_dsym.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_hook_discovery.dart';
import 'package:xcross/src/flutter/build/internal/native_assets_manifest.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/ios_aot_toolchain.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/dart_defines.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/package_config_resolver.dart';

/// Product kernel/assets through Flutter's build graph, followed by the native
/// host iOS ARM64 snapshotter. No debug stub or JIT payload is packaged.
final class FlutterReleaseBundler {
  const FlutterReleaseBundler({
    required this.projectRoot,
    required this.flutterRoot,
    required this.outputDir,
    required this.deploymentTarget,
    required this.options,
  });

  final String projectRoot;
  final String flutterRoot;
  final String outputDir;
  final IosDeploymentTarget deploymentTarget;
  final FlutterBuildOptions options;

  Future<({String framework, List<String> nativeFrameworks})> build() async {
    final compiler = await IosAotToolchain.resolve(flutterRoot);
    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      mode: FlutterBuildMode.release,
    );
    await cache.ensureArtifactsAvailable();
    final output = Directory(outputDir);
    await output.create(recursive: true);
    // Each adapter/AOT invocation owns its intermediates. Kernel depfiles and
    // object paths must not race or refer to files from an older invocation.
    final build = await output.createTemp('build-');
    final hasHooks = await hasNativeAssetsBuildHooks(
      projectRoot,
      includeLinkHooks: true,
    );
    final tools = hasHooks
        ? await AppleToolShimConfig.resolve(deploymentTarget.version)
        : null;
    final shims = p.join(build.path, 'apple-tools');
    if (tools != null) {
      final forwarder = await resolveNativeAssetToolForwarder(
        Platform.resolvedExecutable,
        requireNative: true,
      );
      if (forwarder == null) {
        throw FlutterBuildError(
          'Release native assets require a built xcross executable on PATH.',
        );
      }
      await installAppleToolShims(
        shims,
        tools,
        toolForwarderExecutable: forwarder,
        release: true,
      );
    }
    final adapter = File(p.join(build.path, 'adapter.dart'));
    await adapter.writeAsString(flutterReleaseAdapterSource);
    final request = File(p.join(build.path, 'request.json'));
    await request.writeAsString(
      jsonEncode({
        'flutterRoot': flutterRoot,
        'projectRoot': projectRoot,
        'output': build.path,
        'packageConfig': await PackageConfigResolver.require(projectRoot),
        'engineHash': cache.engineHash,
        'patchedSdk': cache.patchedSdkRoot,
        'defines': {
          'BuildMode': 'release',
          'TargetPlatform': 'ios',
          'IosArchs': 'arm64',
          'TargetFile': p.normalize(p.join(projectRoot, options.target)),
          'IosDeploymentTarget': deploymentTarget.version,
          if (tools != null) 'SdkRoot': tools.iosSdk,
          'DartDefines': DartDefines.withFlavor(
            options.dartDefines,
            options.flavor,
          ).map((value) => base64Encode(utf8.encode(value))).join(','),
          'TreeShakeIcons': 'false',
          'TrackWidgetCreation': 'false',
          'DeferredComponents': 'false',
          if (options.flavor != null) 'Flavor': options.flavor,
        },
      }),
    );
    try {
      await Log.logStep(
        'Building release kernel and assets',
        () => ProcessRunner.runChecked(
          p.join(
            flutterRoot,
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            Platform.isWindows ? 'dart.exe' : 'dart',
          ),
          [
            '--packages=${p.join(flutterRoot, 'packages', 'flutter_tools', '.dart_tool', 'package_config.json')}',
            adapter.path,
            request.path,
          ],
          workingDirectory: projectRoot,
          environment: tools == null
              ? null
              : {
                  'PATH':
                      '$shims${Platform.isWindows ? ';' : ':'}${ProcessRunner.environmentValue(ProcessRunner.effectiveEnvironment, 'PATH') ?? ''}',
                },
          label: 'Flutter release adapter',
        ),
      );
    } finally {
      // Defines may include credentials; never retain the request or print it.
      await request.delete();
    }
    final framework = p.join(build.path, 'App.framework');
    await Directory(framework).create();
    final binary = p.join(framework, 'App');
    final kernel = p.join(build.path, 'app.dill');
    final symbolDirectory = options.splitDebugInfo == null
        ? null
        : p.absolute(projectRoot, options.splitDebugInfo);
    if (symbolDirectory != null) {
      await Directory(symbolDirectory).create(recursive: true);
    }
    final symbols = symbolDirectory == null
        ? null
        : p.join(build.path, 'app.ios-arm64.symbols');
    await Log.logStep(
      'Compiling iOS ARM64 AOT',
      () => ProcessRunner.runChecked(
        compiler.executable,
        [
          '--deterministic',
          '--snapshot_kind=app-aot-macho-dylib',
          '--macho=$binary',
          '--macho-object=${p.join(build.path, 'app.o')}',
          '--macho-min-os-version=${deploymentTarget.version}',
          '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks',
          '--macho-install-name=@rpath/App.framework/App',
          if (symbols != null) ...[
            '--dwarf-stack-traces',
            '--resolve-dwarf-paths',
            '--save-debugging-info=$symbols',
          ],
          if (options.obfuscate) '--obfuscate',
          kernel,
        ],
        workingDirectory: build.path,
        label: 'iOS gen_snapshot',
      ),
    );
    final dsym = p.join(build.path, 'App.framework.dSYM');
    await ProcessRunner.runChecked(await ProcessRunner.locateTool('dsymutil'), [
      binary,
      '-o',
      dsym,
    ], label: 'dsymutil');
    final uuid = await verifyIosDsym(binary, dsym);
    if (symbols != null) {
      await verifyIosDsym(binary, symbols);
      final compatible = File(
        p.join(build.path, 'app.ios-arm64.flutter.symbols'),
      );
      await compatible.writeAsBytes(
        makeFlutterCompatibleDartSymbols(await File(symbols).readAsBytes()),
      );
      await verifyIosDsym(binary, compatible.path);
      // Preserve UUID-specific files and publish the convenient latest alias
      // under a lock even when different projects share the symbol directory.
      await withBuildLock(
        p.join(symbolDirectory!, '.xcross-symbols.lock'),
        () async {
          for (final name in [
            'app.ios-arm64.$uuid.symbols',
            'app.ios-arm64.symbols',
          ]) {
            final target = p.join(symbolDirectory, name);
            final pending = '$target.part';
            await compatible.copy(pending);
            await File(pending).rename(target);
          }
        },
      );
    }
    await ProcessRunner.runChecked(
      await ProcessRunner.locateTool('llvm-strip'),
      ['-x', binary],
      label: 'strip iOS AOT',
    );
    await MachOSigner.preflight(binary);
    final artifact = inspectIosAotArtifact(
      await File(binary).readAsBytes(),
      snapshotHash: IosAotToolchain.snapshotHash,
      minimumOS: deploymentTarget.version,
    );
    await File(p.join(framework, 'Info.plist')).writeAsString(
      FlutterDebugBundler.appFrameworkInfoPlist(deploymentTarget),
    );
    await copyDirectoryPreservingSymlinks(
      p.join(build.path, 'flutter_assets'),
      p.join(framework, 'flutter_assets'),
    );
    final manifest = File(
      p.join(framework, 'flutter_assets', 'NativeAssetsManifest.json'),
    );
    final normalized = normalizeIosNativeAssetsManifest(
      await manifest.readAsString(),
    );
    await manifest.writeAsString(normalized);
    final nativeFrameworks = await stageNativeAssetFrameworks(
      collectNativeAssetFrameworks(normalized, build.path),
      build.path,
    );
    if (tools != null) {
      await thinFrameworksToArm64(nativeFrameworks, lipo: tools.lipo);
      await alignNativeAssetLinkedit(nativeFrameworks);
      await normalizeNativeAssetInstallNames(nativeFrameworks);
      for (final native in nativeFrameworks) {
        final nativeBinary = p.join(native, p.basenameWithoutExtension(native));
        await MachOSigner.preflight(nativeBinary);
        final nativeDsym = p.join(
          build.path,
          'native_assets',
          '${p.basename(native)}.dSYM',
        );
        await verifyIosDsym(nativeBinary, nativeDsym);
      }
    }
    for (final name in [
      'kernel_blob.bin',
      'vm_snapshot_data',
      'isolate_snapshot_data',
      'app.dill',
    ]) {
      if (File(p.join(framework, 'flutter_assets', name)).existsSync()) {
        throw FlutterBuildError(
          'Unexpected JIT payload in release assets: $name',
        );
      }
    }
    await File(p.join(build.path, 'release-evidence.json')).writeAsString(
      jsonEncode({
        'mode': 'release',
        'obfuscate': options.obfuscate,
        'dartSymbols': symbols,
        'engine': cache.engineHash,
        'snapshotterSha256': compiler.manifest['binarySha256'],
        'kernelSha256': sha256
            .convert(await File(kernel).readAsBytes())
            .toString(),
        'appSha256': sha256
            .convert(await File(binary).readAsBytes())
            .toString(),
        'uuid': uuid,
        'artifact': artifact,
        'dsym': dsym,
      }),
    );
    return (framework: framework, nativeFrameworks: nativeFrameworks);
  }
}
