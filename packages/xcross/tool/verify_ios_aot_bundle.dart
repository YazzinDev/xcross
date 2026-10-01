import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_aot_toolchain.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/self_update.dart';

/// Exercise installed-layout discovery without a developer manifest override.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Usage: verify_ios_aot_bundle.dart <bundle-root>');
  }
  final bundle = p.absolute(arguments.single);
  await verify(bundle);
  final installation = await Directory.systemTemp.createTemp(
    'xcross-aot-install-',
  );
  try {
    final bin = await Directory(p.join(installation.path, 'bin')).create();
    final lib = await Directory(p.join(installation.path, 'lib')).create();
    await SelfUpdate.installBundle(
      bundleRoot: Directory(bundle),
      layout: InstallLayout(
        binaryPath: p.join(
          bin.path,
          Platform.isWindows ? 'xcross.exe' : 'xcross',
        ),
        binDir: bin.path,
        libDir: lib.path,
      ),
      label: 'isolated AOT bundle verification',
    );
    await verify(installation.path);
  } finally {
    await installation.delete(recursive: true);
  }
}

Future<void> verify(String bundle) async {
  final compiler = await IosAotToolchain.loadCompiler(
    launcherPath: p.join(
      bundle,
      'bin',
      Platform.isWindows ? 'xcross.exe' : 'xcross',
    ),
    environment: const {},
  );
  final notices = await File(
    p.join(bundle, 'lib', 'ios-aot-NOTICES.txt'),
  ).readAsString();
  if (!notices.contains('Dart project authors') ||
      !notices.contains('UNICODE LICENSE')) {
    throw StateError('Compiler dependency notices are incomplete');
  }
  final result = await Process.run(compiler.executable, ['--version']);
  if (result.exitCode != 0) {
    throw StateError('Packaged compiler cannot execute: ${result.stderr}');
  }
  stdout.writeln(
    'Bundled compiler resolved, verified and executed: ${compiler.manifest['host']}',
  );
}
