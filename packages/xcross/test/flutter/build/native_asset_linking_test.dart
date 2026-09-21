import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/native_asset_frameworks.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/build/runner_shim.dart';

void main() {
  test('collects assemble and project build-hook frameworks', () {
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
    Directory(p.join(output, 'native_assets', 'not-a-framework')).createSync();
    final frameworks = collectNativeAssetFrameworks(
      output,
      projectRoot: root.path,
    );
    expect(frameworks, unorderedEquals([assembled, hooked]));
    expect(collectNativeAssetFrameworks(output), [assembled]);
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
      expect(arguments, containsAllInOrder(['-F', p.dirname(framework)]));
      expect(
        arguments,
        containsAllInOrder([
          '-framework',
          p.basenameWithoutExtension(framework),
        ]),
      );
    }
  });
}
