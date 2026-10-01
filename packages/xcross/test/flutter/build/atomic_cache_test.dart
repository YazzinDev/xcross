import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/atomic_cache.dart';
import 'package:xcross/src/flutter/build/internal/build_lock.dart';

void main() {
  late Directory temp;
  setUp(
    () => temp = Directory.systemTemp.createTempSync('xcross ä atomic cache '),
  );
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'concurrent publishers expose only a complete cache and populate once',
    () async {
      final destination = p.join(temp.path, 'cache');
      final started = Completer<void>();
      final proceed = Completer<void>();
      var calls = 0;
      bool complete(String path) => File(p.join(path, 'ready')).existsSync();
      Future<void> publish() => ensureAtomicCache(
        destination: destination,
        isComplete: complete,
        populate: (stage) async {
          calls++;
          started.complete();
          await File(p.join(stage, 'partial')).writeAsString('partial');
          await proceed.future;
          await File(p.join(stage, 'ready')).writeAsString('complete');
        },
      );
      final first = publish();
      await started.future;
      final second = publish();
      expect(Directory(destination).existsSync(), isFalse);
      proceed.complete();
      await Future.wait([first, second]);
      expect(calls, 1);
      expect(complete(destination), isTrue);
    },
  );

  test(
    'failed validation preserves old input and retry replaces incomplete cache',
    () async {
      final destination = p.join(temp.path, 'cache');
      final old = File(p.join(destination, 'old'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      bool complete(String path) => File(p.join(path, 'ready')).existsSync();
      await expectLater(
        ensureAtomicCache(
          destination: destination,
          isComplete: complete,
          populate: (stage) async {
            await File(p.join(stage, 'partial')).writeAsString('partial');
          },
        ),
        throwsA(anything),
      );
      expect(old.readAsStringSync(), 'old');
      await ensureAtomicCache(
        destination: destination,
        isComplete: complete,
        populate: (stage) async {
          await File(p.join(stage, 'ready')).writeAsString('ready');
        },
      );
      expect(old.existsSync(), isFalse);
      expect(complete(destination), isTrue);
      expect(temp.listSync().whereType<Directory>().length, 1);
    },
  );

  test('lock is reentrant and releases after exceptions', () async {
    final lock = p.join(temp.path, 'state.lock');
    await expectLater(
      withBuildLock(
        lock,
        () =>
            withBuildLock(lock, () => Future<void>.error(StateError('failed'))),
      ),
      throwsStateError,
    );
    expect(await withBuildLock(lock, () async => 42), 42);
  });

  test(
    'separate processes serialize shared writes with spaces and Unicode',
    () async {
      final count = File(p.join(temp.path, 'count'))..writeAsStringSync('0');
      final packageConfig = p.absolute('../../.dart_tool/package_config.json');
      final worker = p.absolute(
        'test/flutter/build/support/build_lock_worker.dart',
      );
      final results = await Future.wait(
        List.generate(
          3,
          (_) => Process.run(Platform.resolvedExecutable, [
            '--packages=$packageConfig',
            worker,
            p.join(temp.path, 'state.lock'),
            count.path,
          ]),
        ),
      ).timeout(const Duration(seconds: 30));
      for (final result in results) {
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      expect(count.readAsStringSync(), '36');
    },
  );
}
