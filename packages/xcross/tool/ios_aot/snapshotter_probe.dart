import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_aot_toolchain.dart';

import 'snapshotter_context.dart';
import 'snapshotter_inspection.dart';

/// Produce and inspect a real Product Mach-O using a manifest-verified compiler.
Future<Map<String, Object>> compileSnapshotterKernel(
  SnapshotterContext context, {
  required String manifest,
  required String kernel,
  required String output,
}) async {
  final compiler = await IosAotToolchain.loadCompiler(manifestPath: manifest);
  final binary = p.join(output, 'App.framework', 'App');
  final object = p.join(output, 'app.o');
  await context.assertPrivate(binary);
  await context.assertPrivate(object);
  await File(binary).parent.create(recursive: true);
  final arguments = [
    '--deterministic',
    '--snapshot_kind=app-aot-macho-dylib',
    '--macho=$binary',
    '--macho-object=$object',
    '--macho-min-os-version=13.0',
    '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks',
    '--macho-install-name=@rpath/App.framework/App',
    kernel,
  ];
  await context.run(
    compiler.executable,
    arguments,
    cwd: output,
    log: p.join(output, 'snapshotter.log'),
  );
  return {
    'snapshotterCommand': [compiler.executable, ...arguments],
    'binarySha256': await fileSha256(compiler.executable),
    'host': inspectSnapshotterHost(
      await File(compiler.executable).readAsBytes(),
      context.host,
    ),
    'kernelSha256': await fileSha256(kernel),
    'machoSha256': await fileSha256(binary),
    'artifact': inspectSnapshotterProduct(
      await File(binary).readAsBytes(),
      context.pins['snapshotHash'] as String,
    ),
  };
}

/// Pinned private frontend used by the release archive gate on each host.
Future<void> verifySnapshotterPackage(
  SnapshotterContext context,
  String bundle,
) => context.locked(() async {
  final output = p.join(context.cache, 'package-validation');
  final sdk = p.join(output, 'dart-sdk');
  final frontend = p.join(
    sdk,
    'bin',
    'snapshots',
    'frontend_server_aot.dart.snapshot',
  );
  if (!File(frontend).existsSync()) {
    await context.extract(
      await context.download('dart-sdk-${context.host}.zip'),
      sdk,
      memberRoot: 'dart-sdk',
    );
  }
  requireSnapshotter(
    (await File(p.join(sdk, 'revision')).readAsString()).trim() ==
        context.pins['dartRevision'],
    'Validation frontend does not match the compiler',
  );
  final runtime = p.join(sdk, 'bin', 'dartaotruntime${context.suffix}');
  await context.executable(runtime);
  final platform = p.join(output, 'flutter_patched_sdk_product');
  if (!File(p.join(platform, 'platform_strong.dill')).existsSync()) {
    await context.extract(
      await context.download('flutter_patched_sdk_product.zip'),
      platform,
      memberRoot: 'flutter_patched_sdk_product',
    );
  }
  final config = p.join(output, 'package_config.json');
  await context.writeJson(config, {'configVersion': 2, 'packages': <Object>[]});
  final kernel = p.join(output, 'smoke.dill');
  await context.assertPrivate(kernel);
  await context.run(
    runtime,
    [
      frontend,
      '--sdk-root',
      '$platform/',
      '--target=flutter',
      '--aot',
      '--tfa',
      '--target-os',
      'ios',
      '-Ddart.vm.product=true',
      '-Ddart.vm.profile=false',
      '--packages',
      config,
      '--output-dill',
      kernel,
      p.join(context.recipe, 'fixture', 'snapshotter_smoke.dart'),
    ],
    cwd: output,
    log: p.join(output, 'frontend.log'),
  );
  final evidence = await compileSnapshotterKernel(
    context,
    manifest: p.join(p.absolute(bundle), 'lib', IosAotToolchain.manifestName),
    kernel: kernel,
    output: output,
  );
  await context.writeJson(p.join(output, 'evidence.json'), evidence);
  stdout.writeln(
    'Packaged ${context.host} compiler produced a verified iOS ARM64 Product snapshot.',
  );
});
