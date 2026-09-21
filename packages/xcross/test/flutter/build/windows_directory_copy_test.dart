import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

void main() {
  String plan(String source, {String kind = 'directory'}) => jsonEncode({
    'copyCommands': {
      'framework-copy': {
        'inputs': [
          {'kind': kind, 'name': source},
        ],
        'outputs': [
          {'kind': 'directory', 'name': r'D:\build\Example.framework'},
        ],
      },
    },
    'unrelated': source,
  });

  test(
    'normalizes extended drive directory sources without changing nodes',
    () {
      final source = '${r'\\?\e:\'}${r'nested\' * 50}Example.framework';
      final original = plan(source);
      final result =
          GeneratedPluginsPackage.normalizeWindowsDirectoryCopyInputs(original);
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      final commands = decoded['copyCommands'] as Map<String, dynamic>;
      final command = commands['framework-copy'] as Map<String, dynamic>;
      expect((command['inputs'] as List<dynamic>).single, {
        'kind': 'directory',
        'name': source.substring(4),
      });
      expect((command['outputs'] as List<dynamic>).single, {
        'kind': 'directory',
        'name': r'D:\build\Example.framework',
      });
      expect(decoded['unrelated'], source);
      expect(
        GeneratedPluginsPackage.normalizeWindowsDirectoryCopyInputs(result),
        result,
      );
    },
  );

  test('preserves ordinary paths, UNC paths, files and unrelated plans', () {
    for (final original in [
      plan(r'C:\Example.framework'),
      plan('/tmp/Example.framework'),
      plan(r'\\?\UNC\server\share\Example.framework'),
      plan(r'\\?\C:\example.txt', kind: 'file'),
      '{ "swiftCommands": {} }',
    ]) {
      expect(
        GeneratedPluginsPackage.normalizeWindowsDirectoryCopyInputs(original),
        original,
      );
    }
  });

  test('generated-file repair is Windows-only and idempotent', () async {
    final scratch = await Directory.systemTemp.createTemp('xcross-copy-plan-');
    addTearDown(() => scratch.delete(recursive: true));
    final target = await Directory(p.join(scratch.path, 'debug')).create();
    final description = File(p.join(target.path, 'description.json'));
    final original = plan(r'\\?\C:\vendor\Example.framework');
    await description.writeAsString(original);
    expect(
      await GeneratedPluginsPackage.repairWindowsGeneratedBuildFiles(
        scratch.path,
        target.path,
        windows: false,
      ),
      isFalse,
    );
    expect(await description.readAsString(), original);
    expect(
      await GeneratedPluginsPackage.repairWindowsGeneratedBuildFiles(
        scratch.path,
        target.path,
        windows: true,
      ),
      isTrue,
    );
    expect(
      await GeneratedPluginsPackage.repairWindowsGeneratedBuildFiles(
        scratch.path,
        target.path,
        windows: true,
      ),
      isFalse,
    );
  });
}
