import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'ios_aot/snapshotter_context.dart';
import 'ios_aot/snapshotter_inspection.dart';
import 'ios_aot/snapshotter_probe.dart';

/// Compile the Flutter fixture without modifying its installed SDK.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter-root', mandatory: true)
    ..addOption('manifest')
    ..addFlag('kernel-only', negatable: false);
  final options = parser.parse(arguments);
  final context = SnapshotterContext(findSnapshotterRepository());
  await context.locked(() async {
    final flutter = p.absolute(options['flutter-root'] as String);
    requireSnapshotter(
      await context.run('git', ['rev-parse', 'HEAD'], cwd: flutter) ==
          context.pins['flutterRevision'],
      'Unsupported Flutter revision',
    );
    final sdk = p.join(flutter, 'bin', 'cache', 'dart-sdk');
    for (final entry in {
      p.join(sdk, 'revision'): 'dartRevision',
      p.join(flutter, 'bin', 'internal', 'engine.version'): 'engineArtifactKey',
    }.entries) {
      requireSnapshotter(
        (await File(entry.key).readAsString()).trim() ==
            context.pins[entry.value],
        'Installed SDK does not match pinned ${entry.value}',
      );
    }
    final fixture = p.join(context.recipe, 'fixture');
    final packages = p.join(fixture, '.dart_tool', 'package_config.json');
    requireSnapshotter(
      File(packages).existsSync(),
      'Run the selected Flutter pub get in $fixture',
    );
    final output = p.join(context.cache, 'probe');
    final platform = p.join(
      flutter,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'common',
      'flutter_patched_sdk_product',
    );
    final kernel = p.join(output, 'app.dill');
    final depfile = p.join(output, 'app.d');
    await context.assertPrivate(kernel);
    await context.assertPrivate(depfile);
    await Directory(output).create(recursive: true);
    final frontend = p.join(
      sdk,
      'bin',
      'snapshots',
      'frontend_server_aot.dart.snapshot',
    );
    final runtime = p.join(sdk, 'bin', 'dartaotruntime${context.suffix}');
    final command = [
      frontend,
      '--sdk-root',
      '$platform/',
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=true',
      '--delete-tostring-package-uri=dart:ui',
      '--delete-tostring-package-uri=package:flutter',
      '--aot',
      '--tfa',
      '--target-os',
      'ios',
      '--packages',
      packages,
      '--output-dill',
      kernel,
      '--depfile',
      depfile,
      '--verbosity=error',
      for (final entry in readObject(p.join(fixture, 'defines.json')).entries)
        '-D${entry.key}=${entry.value}',
      'package:xcross_ios_aot_probe/main.dart',
    ];
    await context.run(
      runtime,
      command,
      cwd: fixture,
      log: p.join(output, 'frontend.log'),
    );
    requireSnapshotter(
      await File(kernel).length() > 0,
      'Frontend produced no kernel',
    );
    final record = <String, Object>{
      'pins': context.pins,
      'frontendCommand': [runtime, ...command],
      'kernelSha256': await fileSha256(kernel),
      'frontendSha256': await fileSha256(frontend),
      'platformSha256': await fileSha256(
        p.join(platform, 'platform_strong.dill'),
      ),
    };
    if (!(options['kernel-only'] as bool)) {
      record.addAll(
        await compileSnapshotterKernel(
          context,
          manifest:
              options['manifest'] as String? ??
              p.join(context.cache, 'snapshotter-manifest.json'),
          kernel: kernel,
          output: output,
        ),
      );
    }
    await context.writeJson(p.join(output, 'evidence.json'), record);
    stdout.writeln('Compiler outputs recorded at $output');
  });
}
