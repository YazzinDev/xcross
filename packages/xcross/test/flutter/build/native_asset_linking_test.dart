import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  test(
    'links only native frameworks needed by SwiftPM plugin symbols',
    () async {
      final root = Directory.systemTemp.createTempSync('xcross-native-links-');
      addTearDown(() => root.deleteSync(recursive: true));
      final provider = p.join(root.path, 'flutter_soloud_plugin.framework');
      final unused = p.join(root.path, 'objective_c.framework');
      Directory(provider).createSync();
      Directory(unused).createSync();
      _writeMachO(
        p.join(provider, 'flutter_soloud_plugin'),
        '_clearDartCallbackRegistrationsForEngine',
        undefined: false,
      );
      _writeMachO(
        p.join(unused, 'objective_c'),
        '_unrelated',
        undefined: false,
      );
      final plugin = p.join(root.path, 'libflutter-soloud.dylib');
      _writeMachO(
        plugin,
        '_clearDartCallbackRegistrationsForEngine',
        undefined: true,
      );

      final required = await nativeFrameworksRequiredByPlugins(
        [provider, unused],
        [plugin],
      );
      expect(required, [provider]);
      final arguments = RunnerShim.linkArguments(
        objectPath: 'Runner.o',
        outputPath: 'Runner',
        iosSdk: '/sdk',
        flutterSlice: '/engine',
        subframeworks: '/subframeworks',
        sdkVersion: '26.0',
        deploymentTarget: const IosDeploymentTarget('17.0'),
        nativeAssetFrameworks: required,
      );
      expect(
        arguments,
        containsAllInOrder(['-needed_framework', 'flutter_soloud_plugin']),
      );
      expect(arguments, isNot(contains('objective_c')));
      expect(
        await nativeFrameworksRequiredByPlugins([provider, unused], const []),
        isEmpty,
      );
    },
  );

  test('collects only frameworks referenced by the active manifest', () {
    final root = Directory.systemTemp.createTempSync('xcross-hook-products-');
    addTearDown(() => root.deleteSync(recursive: true));
    final output = p.join(root.path, 'assemble');
    final assembled = p.join(output, 'native_assets', 'First.framework');
    final hooked = p.join(
      root.path,
      'build',
      'native_assets',
      'ios',
      'Second.framework',
    );
    Directory(assembled).createSync(recursive: true);
    Directory(hooked).createSync(recursive: true);
    final stale = p.join(output, 'native_assets', 'Stale.framework');
    Directory(stale).createSync(recursive: true);
    final manifest = jsonEncode({
      'native-assets': {
        'ios_arm64': {
          'first': ['absolute', 'First.framework/First'],
          'second': ['relative', 'Second.framework/Second'],
        },
        'ios_x64': {
          'simulator': ['absolute', 'Stale.framework/Stale'],
        },
      },
    });
    final frameworks = collectNativeAssetFrameworks(
      manifest,
      output,
      projectRoot: root.path,
    );
    expect(frameworks, unorderedEquals([assembled, hooked]));
    expect(frameworks, isNot(contains(stale)));
    final arguments = RunnerShim.linkArguments(
      objectPath: 'Runner.o',
      outputPath: 'Runner',
      iosSdk: '/sdk',
      flutterSlice: '/engine',
      subframeworks: '/subframeworks',
      sdkVersion: '26.0',
      deploymentTarget: const IosDeploymentTarget('17.0'),
      nativeAssetFrameworks: frameworks,
    );
    for (final framework in frameworks) {
      expect(
        arguments,
        containsAllInOrder([
          '-F',
          p.dirname(framework),
          '-needed_framework',
          p.basenameWithoutExtension(framework),
        ]),
      );
    }
    expect(arguments, isNot(contains('Stale')));
  });

  test('rejects missing manifest frameworks and prefers current outputs', () {
    final root = Directory.systemTemp.createTempSync('xcross-asset-conflict-');
    addTearDown(() => root.deleteSync(recursive: true));
    final output = p.join(root.path, 'assemble');
    final manifest = jsonEncode({
      'native-assets': {
        'ios_arm64': {
          'asset': ['absolute', 'Shared.framework/Shared'],
        },
      },
    });
    expect(
      () => collectNativeAssetFrameworks(
        manifest,
        output,
        projectRoot: root.path,
      ),
      throwsA(isA<FlutterBuildError>()),
    );
    final current = p.join(output, 'native_assets', 'Shared.framework');
    final stale = p.join(
      root.path,
      'build',
      'native_assets',
      'ios',
      'Shared.framework',
    );
    Directory(current).createSync(recursive: true);
    Directory(stale).createSync(recursive: true);
    File(p.join(current, 'Shared')).writeAsStringSync('current');
    File(p.join(stale, 'Shared')).writeAsStringSync('stale');
    final selected = collectNativeAssetFrameworks(
      manifest,
      output,
      projectRoot: root.path,
    );
    expect(selected, [current]);
    expect(
      File(p.join(selected.single, 'Shared')).readAsStringSync(),
      'current',
    );
  });
}

void _writeMachO(String path, String symbol, {required bool undefined}) {
  const headerSize = 32;
  const commandSize = 24;
  const symbolSize = 16;
  final strings = [0, ...symbol.codeUnits, 0];
  const symbolOffset = headerSize + commandSize;
  const stringsOffset = symbolOffset + symbolSize;
  final bytes = Uint8List(stringsOffset + strings.length);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0xFEED_FACF, Endian.little);
  data.setUint32(4, 0x0100_000c, Endian.little);
  data.setUint32(12, 0x6, Endian.little);
  data.setUint32(16, 1, Endian.little);
  data.setUint32(20, commandSize, Endian.little);
  data.setUint32(headerSize, 0x2, Endian.little);
  data.setUint32(headerSize + 4, commandSize, Endian.little);
  data.setUint32(headerSize + 8, symbolOffset, Endian.little);
  data.setUint32(headerSize + 12, 1, Endian.little);
  data.setUint32(headerSize + 16, stringsOffset, Endian.little);
  data.setUint32(headerSize + 20, strings.length, Endian.little);
  data.setUint32(symbolOffset, 1, Endian.little);
  bytes[symbolOffset + 4] = undefined ? 0x01 : 0x0f;
  bytes[symbolOffset + 5] = undefined ? 0 : 1;
  bytes.setRange(stringsOffset, bytes.length, strings);
  File(path).writeAsBytesSync(bytes);
}
