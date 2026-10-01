import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/clean_command.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';

void main() {
  test('clean is registered by the top-level runner', () {
    expect(XcrossCli.buildRunner().commands.keys, contains('clean'));
  });

  test('removes project native assets and SwiftPM workspace', () async {
    final project = Directory.systemTemp.createTempSync('xcross_clean_project');
    final cache = Directory.systemTemp.createTempSync('xcross_clean_cache');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });
    final nativeAssets = Directory(
      p.join(project.path, 'build', 'xcross-native-assets'),
    )..createSync(recursive: true);
    final intermediates = Directory(
      p.join(project.path, 'build', 'xcross-flutter-release', 'build-old'),
    )..createSync(recursive: true);
    final workspace = SwiftPmWorkspace.forProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );
    final swiftPm = Directory(workspace.root)..createSync(recursive: true);
    final release = Directory(
      SwiftPmWorkspace.forProject(
        project.path,
        environment: {'XCROSS_CACHE_DIR': cache.path},
        mode: FlutterBuildMode.release,
      ).root,
    )..createSync(recursive: true);

    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );

    expect(nativeAssets.existsSync(), isFalse);
    expect(intermediates.existsSync(), isFalse);
    expect(swiftPm.existsSync(), isFalse);
    expect(release.existsSync(), isFalse);
  });

  test('preserves unrelated build output and shared SwiftPM caches', () async {
    final project = Directory.systemTemp.createTempSync('xcross_clean_project');
    final cache = Directory.systemTemp.createTempSync('xcross_clean_cache');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });
    final unrelated = File(p.join(project.path, 'build', 'keep.txt'))
      ..createSync(recursive: true);
    final symbols = File(
      p.join(
        project.path,
        'build',
        'xcross-ios-release-symbols',
        'uuid',
        'App.framework.dSYM',
        'symbol',
      ),
    )..createSync(recursive: true);
    final shared = File(
      p.join(cache.path, 'swiftpm', 'binary-artifacts-v1', 'keep.txt'),
    )..createSync(recursive: true);

    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );

    expect(unrelated.existsSync(), isTrue);
    expect(symbols.existsSync(), isTrue);
    expect(shared.existsSync(), isTrue);
  });

  test('succeeds when project caches do not exist', () async {
    final project = Directory.systemTemp.createTempSync('xcross_clean_project');
    final cache = Directory.systemTemp.createTempSync('xcross_clean_cache');
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );
    await CleanCommand.cleanProject(
      project.path,
      environment: {'XCROSS_CACHE_DIR': cache.path},
    );
  });
}
