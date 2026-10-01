import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

Future<void> main(List<String> arguments) => build(arguments, (
  input,
  output,
) async {
  if (input.config.code.targetOS != OS.iOS ||
      input.config.code.targetArchitecture != Architecture.arm64) {
    throw StateError('This fixture must compile for iOS ARM64.');
  }
  await CBuilder.library(
    name: 'xcross_ffi_probe',
    assetName: 'probe.dart',
    sources: ['src/probe.c'],
    flags: ['-g'],
  ).run(input: input, output: output, routing: [ToLinkHook(input.packageName)]);
});
