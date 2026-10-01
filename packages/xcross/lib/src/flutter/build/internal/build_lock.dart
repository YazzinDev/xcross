import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

final _tails = <String, Future<void>>{};
final _heldLocks = Object();

/// Serialize related build state within this isolate and across processes.
/// The OS releases its lock on process exit; the lock file itself is retained.
Future<T> withBuildLock<T>(String path, Future<T> Function() action) async {
  await Directory(p.dirname(path)).create(recursive: true);
  final parent = await Directory(p.dirname(path)).resolveSymbolicLinks();
  final canonical = p.join(parent, p.basename(path));
  final key = Platform.isWindows ? canonical.toLowerCase() : canonical;
  final held = Zone.current[_heldLocks] as Set<String>? ?? const <String>{};
  if (held.contains(key)) return action();
  final previous = _tails[key];
  final done = Completer<void>();
  _tails[key] = done.future;
  RandomAccessFile? file;
  var locked = false;
  try {
    if (previous != null) await previous;
    file = await File(canonical).open(mode: FileMode.append);
    await file.lock(FileLock.blockingExclusive);
    locked = true;
    return await runZoned(
      action,
      zoneValues: {
        _heldLocks: {...held, key},
      },
    );
  } finally {
    try {
      if (locked) await file!.unlock();
    } finally {
      await file?.close();
      done.complete();
      if (identical(_tails[key], done.future)) {
        final removed = _tails.remove(key);
        assert(identical(removed, done.future), 'Build lock queue changed.');
      }
    }
  }
}

Future<T> withFlutterProjectLock<T>(Future<T> Function() action) =>
    withBuildLock(
      p.join(Directory.current.path, 'build', '.xcross-build.lock'),
      action,
    );
