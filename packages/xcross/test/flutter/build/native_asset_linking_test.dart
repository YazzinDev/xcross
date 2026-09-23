import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
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
