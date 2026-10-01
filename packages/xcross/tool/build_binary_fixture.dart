import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ios_aot/snapshotter_context.dart';

/// Build the static ARM64 XCFramework consumed by the SwiftPM plugin fixture.
Future<void> main(List<String> arguments) async {
  final options =
      (ArgParser()
            ..addOption('clang', mandatory: true)
            ..addOption('ar', mandatory: true)
            ..addOption('sdk', mandatory: true))
          .parse(arguments);
  final root = p.join(findSnapshotterRepository(), 'tool', 'ios_aot');
  final package = p.join(root, 'objc_plugin', 'ios', 'xcross_objc_probe');
  final framework = p.join(package, 'ProbeBinary.xcframework');
  final device = p.join(framework, 'ios-arm64');
  final headers = Directory(p.join(device, 'Headers'));
  await headers.create(recursive: true);
  final object = File(p.join(root, 'objc_plugin', 'build', 'probe.o'));
  await object.parent.create(recursive: true);
  await ProcessRunner.runChecked(options.option('clang')!, [
    '-target',
    'arm64-apple-ios13.0',
    '-isysroot',
    options.option('sdk')!,
    '-O3',
    '-g',
    '-DNDEBUG',
    '-c',
    p.join(package, 'probe_binary.c'),
    '-o',
    object.path,
  ]);
  final library = File(p.join(device, 'libProbeBinary.a'));
  await ProcessRunner.runChecked(options.option('ar')!, [
    'rcsD',
    library.path,
    object.path,
  ]);
  await File(
    p.join(headers.path, 'ProbeBinary.h'),
  ).writeAsString('int xcross_binary_answer(void);\n');
  await File(
    p.join(headers.path, 'module.modulemap'),
  ).writeAsString('module ProbeBinary { header "ProbeBinary.h" export * }\n');
  await File(p.join(framework, 'Info.plist')).writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>XFWK</string>
<key>XCFrameworkFormatVersion</key><string>1.0</string>
<key>AvailableLibraries</key><array><dict>
<key>LibraryIdentifier</key><string>ios-arm64</string>
<key>LibraryPath</key><string>libProbeBinary.a</string>
<key>HeadersPath</key><string>Headers</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array>
<key>SupportedPlatform</key><string>ios</string>
</dict></array></dict></plist>
''');
  stdout.writeln(
    jsonEncode({
      'xcframework': framework,
      'archiveSha256': (await sha256.bind(library.openRead()).first).toString(),
    }),
  );
}
