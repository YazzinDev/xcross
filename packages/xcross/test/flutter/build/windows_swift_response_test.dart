import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

void main() {
  test(
    'externalizes long swift argv and preserves short and other tools',
    () async {
      final root = await Directory.systemTemp.createTemp('xcross response ');
      addTearDown(() => root.delete(recursive: true));
      final arguments = [
        r'C:\Swift Tools\swiftc.exe',
        '-D',
        'A' * 29000,
        r'C:\path with spaces\file.swift',
        'quote"value',
        '',
        r'ends\',
      ];
      final short = '    args: ${jsonEncode(['swiftc.exe', '--version'])}';
      final other = '    args: ${jsonEncode(['other.exe', 'A' * 29000])}';
      final plan = File(p.join(root.path, 'debug.yaml'));
      await plan.writeAsString(
        'commands:\n    args: ${jsonEncode(arguments)}\n$short\n$other\n',
      );
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: false,
        ),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, '.xcross-response')).existsSync(),
        isFalse,
      );
      expect(
        await plan.readAsString(),
        'commands:\n    args: ${jsonEncode(arguments)}\n$short\n$other\n',
      );
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: true,
        ),
        isTrue,
      );
      final lines = await plan.readAsLines();
      final invocation = (jsonDecode(lines[1].substring(10)) as List)
          .cast<String>();
      expect(invocation.first, arguments.first);
      expect(invocation.length, 2);
      expect(invocation.last.startsWith('@'), isTrue);
      final response = await File(invocation.last.substring(1)).readAsLines();
      expect(response, [
        '"-D"',
        '"${'A' * 29000}"',
        r'"C:\path with spaces\file.swift"',
        r'"quote\"value"',
        '""',
        r'"ends\\"',
      ]);
      expect(lines[2], short);
      expect(lines[3], other);
      final content = await plan.readAsString();
      expect(
        await GeneratedPluginsPackage.repairWindowsSwiftResponseFiles(
          root.path,
          windows: true,
        ),
        isFalse,
      );
      expect(await plan.readAsString(), content);
    },
  );
}
