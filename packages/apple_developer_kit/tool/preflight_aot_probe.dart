import 'dart:io';

import 'package:apple_developer_kit/src/signing/macho_signer.dart';

/// Runs the real xcross signer's read-only structural validation on AOT output.
/// Passing this check does not prove an Apple signature or device acceptance.
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('Usage: dart preflight_aot_probe.dart <Mach-O> [<Mach-O> ...]');
    exitCode = 64;
    return;
  }
  for (final path in arguments) {
    await MachOSigner.preflight(path);
    stdout.writeln('Signer preflight passed: $path');
  }
}
