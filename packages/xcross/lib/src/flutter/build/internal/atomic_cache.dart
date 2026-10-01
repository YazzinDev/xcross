import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/build_lock.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Build in an owned sibling directory, validate, then publish by rename.
/// Readers only accept complete artifacts; writers recheck under the lock.
Future<void> ensureAtomicCache({
  required String destination,
  required bool Function(String path) isComplete,
  required Future<void> Function(String stage) populate,
}) => withBuildLock('$destination.lock', () async {
  if (isComplete(destination)) return;
  final target = Directory(destination);
  await target.parent.create(recursive: true);
  final stage = await Directory(
    p.dirname(destination),
  ).createTemp('.xcross-cache-');
  String? previous;
  try {
    await populate(stage.path);
    if (!isComplete(stage.path)) {
      throw FlutterBuildError(
        'Incomplete artifact for $destination; cache was not published.',
      );
    }
    if (target.existsSync()) {
      previous = '${stage.path}.previous';
      await target.rename(previous);
    }
    try {
      await stage.rename(destination);
    } on Object {
      if (previous != null) await Directory(previous).rename(destination);
      rethrow;
    }
    if (previous != null) await Directory(previous).delete(recursive: true);
  } finally {
    if (stage.existsSync()) await stage.delete(recursive: true);
  }
});
