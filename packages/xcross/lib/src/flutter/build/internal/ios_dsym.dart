import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Verify real DWARF and the UUID binding before stripping or signing a binary.
Future<String> verifyIosDsym(String binary, String dsym) async {
  final dwarf = await ProcessRunner.locateTool('llvm-dwarfdump');
  await ProcessRunner.runChecked(dwarf, [
    '--verify',
    dsym,
  ], label: 'dSYM verification');
  final binaryResult = await ProcessRunner.run(dwarf, ['--uuid', binary]);
  final dsymResult = await ProcessRunner.run(dwarf, ['--uuid', dsym]);
  final pattern = RegExp(r'UUID: ([0-9A-Fa-f-]+) \(arm64\)');
  final uuid = pattern.firstMatch(binaryResult.stdout)?.group(1)?.toLowerCase();
  final dsymUuid = pattern
      .firstMatch(dsymResult.stdout)
      ?.group(1)
      ?.toLowerCase();
  if (binaryResult.exitCode != 0 ||
      dsymResult.exitCode != 0 ||
      uuid == null ||
      uuid != dsymUuid) {
    throw FlutterBuildError('ARM64 UUID mismatch between $binary and $dsym.');
  }
  return uuid;
}
