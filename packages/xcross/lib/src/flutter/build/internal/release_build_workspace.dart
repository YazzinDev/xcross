import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/atomic_cache.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';

/// Keep intermediates alive through packaging, then remove only this invocation.
Future<T> withReleaseBuildWorkspace<T>(
  String outputDir,
  Future<T> Function(Directory build) action,
) async {
  final output = Directory(outputDir);
  await output.create(recursive: true);
  final build = await output.createTemp('build-');
  try {
    return await action(build);
  } finally {
    await build.delete(recursive: true);
  }
}

/// Publish UUID-specific symbols separately from disposable build intermediates.
Future<void> preserveReleaseSymbols(Directory build, String destination) =>
    ensureAtomicCache(
      destination: destination,
      isComplete: (path) =>
          File(p.join(path, 'release-evidence.json')).existsSync() &&
          Directory(p.join(path, 'App.framework.dSYM')).existsSync(),
      populate: (stage) async {
        for (final entity in build.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is Directory && entity.path.endsWith('.dSYM')) {
            await copyDirectoryPreservingSymlinks(
              entity.path,
              p.join(stage, p.relative(entity.path, from: build.path)),
            );
          }
        }
        await File(
          p.join(build.path, 'release-evidence.json'),
        ).copy(p.join(stage, 'release-evidence.json'));
      },
    );
