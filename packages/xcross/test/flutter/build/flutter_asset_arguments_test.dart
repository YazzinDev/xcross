import 'dart:convert';

import 'package:args/args.dart';
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/ios_native_assets.dart';

void main() {
  for (final withHooks in [false, true]) {
    group(withHooks ? 'native-hook assembly' : 'bundle assembly', () {
      List<String> arguments(List<String> defines, {String? flavor}) =>
          IosNativeAssetsBuilder(
            projectRoot: '/project with spaces',
            flutterRoot: '/flutter',
            deploymentTarget: const IosDeploymentTarget('15.0'),
            entrypoint: 'lib/entry point.dart',
            dartDefines: defines,
            flavor: flavor,
          ).assembleArguments(
            output: '/output with spaces',
            iosSdk: withHooks ? '/SDK with spaces' : null,
          );

      test('preserves compiler values and flavor without CLI validation', () {
        const defines = ['VALUE=one,two=three ü', 'MODE=first', 'MODE=last'];
        final args = arguments(defines, flavor: 'staging');
        expect(_decodedDefines(args), [
          ...defines,
          'FLUTTER_APP_FLAVOR=staging',
        ]);
        expect(args.first, 'assemble');
        expect(args, contains('-dTargetFile=lib/entry point.dart'));
        expect(args[args.indexOf('-o') + 1], '/output with spaces');
        expect(
          args.last,
          withHooks ? 'debug_ios_bundle_flutter_assets' : 'copy_flutter_bundle',
        );
        expect(args.contains('-dSdkRoot=/SDK with spaces'), withHooks);
      });

      test('keeps the explicit flavor override and its precedence', () {
        const defines = ['FLUTTER_APP_FLAVOR=explicit'];
        expect(_decodedDefines(arguments(defines, flavor: 'staging')), defines);
      });

      test(
        'passes empty and comma-containing values through assemble parsing',
        () {
          const defines = ['EMPTY=', 'VALUE=one,two=three ü', 'MODE=last'];
          final args = arguments(defines);
          // Match Flutter assemble's public options, including the legacy -d
          // comma splitting that must not consume the encoded application values.
          final parser = ArgParser()
            ..addFlag('version-check', defaultsTo: true)
            ..addOption('output', abbr: 'o')
            ..addMultiOption('define', abbr: 'd')
            ..addMultiOption('dart-define', abbr: 'D', splitCommas: false);
          final parsed = parser.parse(args.skip(1));
          expect(
            (parsed['define'] as List<String>).every(
              (value) => value.contains('='),
            ),
            isTrue,
          );
          expect(
            (parsed['dart-define'] as List<String>).map(
              (value) => utf8.decode(base64.decode(value)),
            ),
            defines,
          );
        },
      );

      test('does not invent a flavor for ordinary builds', () {
        expect(_decodedDefines(arguments(const [])), isEmpty);
      });
    });
  }
}

List<String> _decodedDefines(List<String> arguments) {
  return arguments
      .where((argument) => argument.startsWith('--dart-define='))
      .map((argument) => argument.substring('--dart-define='.length))
      .map((value) => utf8.decode(base64.decode(value)))
      .toList();
}
