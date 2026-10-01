import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> arguments) => link(arguments, (
  input,
  output,
) async {
  // Deliberately inspect the real application's recorded-use file. A stub
  // entrypoint or a debug build cannot satisfy this fixture's link contract.
  // ignore: deprecated_member_use
  final uses = input.recordedUsagesFile;
  if (uses == null ||
      !File.fromUri(
        uses,
      ).readAsStringSync().contains('ffi-fixture-real-entrypoint')) {
    throw StateError(
      'The real app recorded-use marker was not passed to the release link hook.',
    );
  }
  output.assets.code.addAll(input.assets.code);
});
