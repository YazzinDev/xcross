import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/version.dart';

import '../../bin/xcrun.dart' as xcrun;

void main() {
  test('falls back without a sidecar or a supported sibling tool', () {
    final directory = Directory.systemTemp.createTempSync('xcross-xcrun-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = p.join(directory.path, 'xcrun.exe');
    expect(
      xcrun.xcrunShimResponse(const [
        '--show-sdk-path',
      ], executable: executable),
      isNull,
    );
    File('$executable.sdk').writeAsStringSync('/sdk');
    File(p.join(directory.path, 'arbitrary.exe')).writeAsStringSync('');
    expect(
      xcrun.xcrunShimResponse(const [
        '--find',
        'arbitrary',
      ], executable: executable),
      isNull,
    );
    expect(
      xcrun.xcrunShimResponse(const [
        '--find',
        'clang',
      ], executable: executable),
      isNull,
    );
  });
  test('rejects an invocation without a tool', () async {
    expect(await xcrun.runXcrun(const []), 1);
  });

  test('returns the exact streamed child exit code', () async {
    final child = await Process.start('sh', const ['-c', 'exit 37']);
    expect(
      await xcrun.runResolvedTool(
        '/ignored',
        const [],
        start: (_, _) async => child,
      ),
      37,
    );
  });

  test('prefers build shims on PATH for known Apple tools', () async {
    final sdk = DarwinSdk('/unused');
    for (final tool in const ['clang', 'otool']) {
      final shim = '/build/shims/$tool';
      expect(
        await xcrun.runXcrun(
          ['--find', tool],
          sdk: sdk,
          findOnPath: (name) async => name == tool ? shim : null,
        ),
        0,
      );
    }
  });

  test('preserves lowercase Windows compiler shim filenames', () async {
    final directory = await Directory.systemTemp.createTemp('xcross-xcrun-');
    try {
      final executable = File(
        '${directory.path}${Platform.pathSeparator}xcrun.exe',
      )..writeAsStringSync('');
      final platform = p.join(directory.path, 'iPhoneOS.platform');
      final sdk = p.join(platform, 'Developer', 'SDKs', 'iPhoneOS26.5.sdk');
      File('${executable.path}.sdk').writeAsStringSync(sdk);
      expect(
        xcrun.xcrunShimResponse(const [
          '--show-sdk-path',
        ], executable: executable.path),
        sdk,
      );
      final clang = File('${directory.path}${Platform.pathSeparator}clang.exe')
        ..writeAsStringSync('');

      expect(
        xcrun.xcrunShimResponse(const [
          '--find',
          'clang',
        ], executable: executable.path),
        clang.path,
      );
      expect(
        xcrun.xcrunShimResponse(const [
          '--version',
        ], executable: executable.path),
        'xcross xcrun ${XcrossVersion.isReleased ? XcrossVersion.current : '0.0.0'}',
      );
      expect(
        xcrun.xcrunShimResponse(const [
          '--sdk',
          'iphoneos',
          '--show-sdk-platform-path',
        ], executable: executable.path),
        platform,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
