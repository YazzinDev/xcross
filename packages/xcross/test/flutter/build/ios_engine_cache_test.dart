import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';

void makeIos(String framework) {
  for (final path in [
    'Info.plist',
    'ios-arm64/Flutter.framework/Info.plist',
    'ios-arm64/Flutter.framework/Flutter',
  ]) {
    File(p.join(framework, path))
      ..createSync(recursive: true)
      ..writeAsStringSync('fixture');
  }
}

void makePatched(String root) {
  for (final name in ['platform_strong.dill', 'vm_outline_strong.dill']) {
    File(p.join(root, name))
      ..createSync(recursive: true)
      ..writeAsStringSync('fixture');
  }
}

void main() {
  late Directory temporaryDirectory;
  late String flutterRoot;
  late String cacheRoot;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'xcross_ios_engine_cache-',
    );
    flutterRoot = p.join(temporaryDirectory.path, 'flutter');
    cacheRoot = p.join(temporaryDirectory.path, 'cache');
    final internal = Directory(p.join(flutterRoot, 'bin', 'internal'));
    await internal.create(recursive: true);
    await File(
      p.join(internal.path, 'engine.version'),
    ).writeAsString('engine-hash\n');
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test(
    'release ignores cached debug artifacts and needs no JIT seeds',
    () async {
      final debug = IosEngineCache(
        flutterRoot: flutterRoot,
        cacheRoot: cacheRoot,
      );
      makeIos(debug.flutterXcframework);
      makePatched(debug.patchedSdkRoot);
      final release = IosEngineCache(
        flutterRoot: flutterRoot,
        cacheRoot: cacheRoot,
        mode: FlutterBuildMode.release,
      );
      expect(release.flutterXcframework, isNot(debug.flutterXcframework));
      expect(release.patchedSdkRoot, endsWith('flutter_patched_sdk_product'));
      makeIos(release.flutterXcframework);
      makePatched(release.patchedSdkRoot);
      // A download attempt would fail: this fixture has no real engine hash.
      await release.ensureArtifactsAvailable();
      expect(File(release.vmSnapshotData).existsSync(), isFalse);
      expect(File(release.isolateSnapshotData).existsSync(), isFalse);
    },
  );

  test('uses per-user cache when SDK artifacts are absent', () {
    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      cacheRoot: cacheRoot,
    );
    final userEngineRoot = p.join(
      cacheRoot,
      'engine-hash',
      'artifacts',
      'engine',
    );

    expect(
      cache.flutterXcframework,
      p.join(userEngineRoot, 'ios', 'Flutter.xcframework'),
    );
    expect(
      cache.patchedSdkRoot,
      p.join(userEngineRoot, 'common', 'flutter_patched_sdk'),
    );
    expect(cache.vmSnapshotData, contains(userEngineRoot));
    expect(cache.isolateSnapshotData, contains(userEngineRoot));
  });

  test('prefers artifacts already present in Flutter SDK', () {
    final flutterSdkEngineRoot = p.join(
      flutterRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
    );
    makeIos(p.join(flutterSdkEngineRoot, 'ios', 'Flutter.xcframework'));
    makePatched(p.join(flutterSdkEngineRoot, 'common', 'flutter_patched_sdk'));

    final cache = IosEngineCache(
      flutterRoot: flutterRoot,
      cacheRoot: cacheRoot,
    );

    expect(
      cache.flutterXcframework,
      p.join(flutterSdkEngineRoot, 'ios', 'Flutter.xcframework'),
    );
    expect(
      cache.patchedSdkRoot,
      p.join(flutterSdkEngineRoot, 'common', 'flutter_patched_sdk'),
    );
  });
}
