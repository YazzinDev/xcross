import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/ios_aot/snapshotter_builder.dart';
import '../../tool/ios_aot/snapshotter_context.dart';
import '../../tool/ios_aot/snapshotter_inspection.dart';
import '../../tool/ios_aot/snapshotter_source_archive.dart';
import '../flutter/build/ios_aot_artifact_test.dart' as macho;

void main() {
  late Directory root;
  late SnapshotterContext context;
  late SnapshotterBuilder builder;

  File write(String path, String text) {
    final file = File(path)..parent.createSync(recursive: true);
    return file..writeAsStringSync(text);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('snapshotter recipe ');
    write(
      p.join(root.path, 'tool', 'ios_aot', 'versions.json'),
      jsonEncode({'dartRevision': 'fixture', 'downloads': <String, Object>{}}),
    );
    context = SnapshotterContext(root.path);
    builder = SnapshotterBuilder(context);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('selects complete LLVM after a partial Swift toolchain', () {
    final swift = p.join(root.path, 'swift', 'bin');
    final llvm = p.join(root.path, 'llvm', 'bin');
    write(p.join(swift, 'clang'), '');
    for (final name in [
      'clang',
      'clang++',
      'llvm-ar',
      'llvm-nm',
      'llvm-objcopy',
      'llvm-readelf',
      'ld.lld',
    ]) {
      write(p.join(llvm, name), '');
    }
    expect(
      findSnapshotterClang(
        'linux-x64',
        path: [swift, llvm].join(Platform.isWindows ? ';' : ':'),
      ),
      p.dirname(llvm),
    );
    expect(() => findSnapshotterClang('linux-x64', path: ''), throwsStateError);
  });

  test(
    'rejects cache escapes and linked files before modifying installed data',
    () async {
      final installed = write(
        p.join(root.path, 'installed-sdk', 'file'),
        'unchanged',
      );
      final linked = p.join(context.cache, 'linked');
      Directory(context.cache).createSync(recursive: true);
      final result = await Process.run(
        Platform.isWindows ? 'fsutil.exe' : 'ln',
        Platform.isWindows
            ? ['hardlink', 'create', linked, installed.path]
            : [installed.path, linked],
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      await expectLater(
        context.writeText(linked, 'modified'),
        throwsStateError,
      );
      await expectLater(
        context.writeText(installed.path, 'modified'),
        throwsStateError,
      );
      expect(installed.readAsStringSync(), 'unchanged');
      expect(
        () => SnapshotterContext(root.path, cacheRoot: root.path),
        throwsArgumentError,
      );
    },
  );

  test('rejects symlink or junction ancestors including pending files', () async {
    final installed = Directory(p.join(root.path, 'installed'))..createSync();
    final linked = p.join(context.cache, 'linked');
    Directory(context.cache).createSync(recursive: true);
    if (Platform.isWindows) {
      final result = await Process.run('cmd.exe', [
        '/c',
        'mklink',
        '/J',
        linked,
        installed.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    } else {
      Link(linked).createSync(installed.path);
    }
    await expectLater(
      context.writeText(p.join(linked, 'new'), 'modified'),
      throwsStateError,
    );
    expect(installed.listSync(), isEmpty);
    // Remove only the link, never its target, before recursive fixture cleanup.
    await Link(linked).delete();
  });

  test(
    'serializes cache writers and releases the lock after failure',
    () async {
      final events = <int>[];
      await Future.wait([
        context.locked(() async {
          events.add(1);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          events.add(2);
        }),
        context.locked(() async => events.add(3)),
      ]);
      expect(events, anyOf(equals([1, 2, 3]), equals([3, 1, 2])));
      await expectLater(
        context.locked<void>(() async => throw StateError('fail')),
        throwsStateError,
      );
      await context.locked(() async => events.add(4));
      expect(events.last, 4);
    },
  );

  test(
    'failed extraction preserves previous tree and removes staging',
    () async {
      final destination = p.join(context.cache, 'tree');
      final old = write(p.join(destination, 'old'), 'old');
      final archive = Archive()
        ..addFile(ArchiveFile.string('valid', 'valid'))
        ..addFile(ArchiveFile.string('../escape', 'bad'));
      final zip = File(p.join(context.cache, 'archive.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      await expectLater(
        context.extract(zip.path, destination),
        throwsStateError,
      );
      expect(old.readAsStringSync(), 'old');
      expect(File(p.join(context.cache, 'escape')).existsSync(), isFalse);
      expect(
        Directory(
          context.cache,
        ).listSync().where((f) => p.basename(f.path).startsWith('.extract-')),
        isEmpty,
      );
    },
  );

  test(
    'extracts tar root, preserves executable modes and publishes immutable binaries',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile.string('root/tool', 'first')..mode = 0x1ed);
      final tar = File(p.join(context.cache, 'archive.tar.gz'))
        ..parent.createSync(recursive: true);
      tar.writeAsBytesSync(
        const GZipEncoder().encode(TarEncoder().encode(archive)),
      );
      final tree = p.join(context.cache, 'tree');
      await context.extract(tar.path, tree, memberRoot: 'root');
      final binary = File(p.join(tree, 'tool'));
      expect(binary.readAsStringSync(), 'first');
      if (!Platform.isWindows) expect(binary.statSync().mode & 0x49, 0x49);
      await builder.publish(binary.path, {
        'binarySha256': await fileSha256(binary.path),
      });
      final manifest = readObject(
        p.join(context.cache, 'snapshotter-manifest.json'),
      );
      final first = File(
        p.join(context.cache, manifest['binaryRelativePath'] as String),
      );
      binary.writeAsStringSync('second');
      await builder.publish(binary.path, {
        'binarySha256': await fileSha256(binary.path),
      });
      final newer = readObject(
        p.join(context.cache, 'snapshotter-manifest.json'),
      );
      expect(first.readAsStringSync(), 'first');
      expect(
        newer['binaryRelativePath'],
        isNot(manifest['binaryRelativePath']),
      );
    },
  );

  test(
    'verifies both new and cached downloads and never publishes corruption',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('verified');
        await request.response.close();
      });
      final downloads = context.pins['downloads'] as Map<String, dynamic>;
      downloads['test.zip'] = {
        'url': 'http://127.0.0.1:${server.port}/test',
        'sha256': sha256.convert(utf8.encode('verified')).toString(),
      };
      final path = await context.download('test.zip');
      expect(await context.download('test.zip'), path);
      File(path).writeAsStringSync('corrupt');
      await expectLater(context.download('test.zip'), throwsStateError);
      downloads['bad.zip'] = {
        'url': 'http://127.0.0.1:${server.port}/bad',
        'sha256': 'wrong',
      };
      await expectLater(context.download('bad.zip'), throwsStateError);
      expect(
        File(p.join(context.cache, 'downloads', 'bad.zip')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'accepts repackaged source downloads but rejects changed files and permissions',
    () async {
      List<int> archive({
        int timestamp = 1,
        int mode = 0x1a4,
        String path = 'source.txt',
        String content = 'verified',
      }) => const GZipEncoder().encode(
        TarEncoder().encode(
          Archive()..addFile(
            ArchiveFile.string(path, content)
              ..mode = mode
              ..lastModTime = timestamp
              ..ownerId = timestamp,
          ),
        ),
      );
      final original = archive();
      var response = archive(timestamp: 200);
      expect(sha256.convert(original), isNot(sha256.convert(response)));
      final expected = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                [
                  'source.txt',
                  'file',
                  0x1a4,
                  sha256.convert(utf8.encode('verified')).toString(),
                ],
              ]),
            ),
          )
          .toString();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.add(response);
        await request.response.close();
      });
      final downloads = context.pins['downloads'] as Map<String, dynamic>;
      final spec = {
        'url': 'http://127.0.0.1:${server.port}/source',
        'tarContentsSha256': expected,
      };
      downloads['source.tar.gz'] = spec;
      final path = await context.download('source.tar.gz');
      // Cached archives may also differ in packaging metadata.
      File(path).writeAsBytesSync(original);
      expect(await context.download('source.tar.gz'), path);
      for (final changed in [
        archive(content: 'tampered'),
        archive(path: 'other.txt'),
        archive(mode: 0x1ed),
      ]) {
        File(path).writeAsBytesSync(changed);
        await expectLater(context.download('source.tar.gz'), throwsStateError);
        response = changed;
        downloads['bad-source.tar.gz'] = spec;
        await expectLater(
          context.download('bad-source.tar.gz'),
          throwsStateError,
        );
        expect(
          File(
            p.join(context.cache, 'downloads', 'bad-source.tar.gz'),
          ).existsSync(),
          isFalse,
        );
      }
      expect(
        Directory(context.cache).listSync().where(
          (entry) => p.basename(entry.path).startsWith('.source-check-'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'source checksums cover every entry and reject ambiguous paths and links',
    () {
      String digest(List<ArchiveFile> entries) {
        final archive = Archive();
        for (final entry in entries) {
          archive.addFile(entry);
        }
        return snapshotterSourceArchiveSha256(
          InputMemoryStream(TarEncoder().encode(archive)),
        );
      }

      final a = ArchiveFile.string('a', 'first');
      final b = ArchiveFile.string('b', 'second');
      expect(digest([a, b]), digest([b, a]));
      expect(digest([a, b]), isNot(digest([a])));
      for (final entries in [
        <ArchiveFile>[],
        [ArchiveFile.string('../outside', 'bad')],
        [ArchiveFile.symlink('link', 'a')],
        [a, ArchiveFile.string('./a', 'duplicate')],
      ]) {
        expect(() => digest(entries), throwsStateError);
      }
    },
  );

  test(
    'patches pristine files, resumes idempotently and rejects unknown source changes',
    () async {
      final patchRoot = p.join(context.recipe, 'patches');
      const patch =
          'diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n';
      final host = context.windows ? 'windows' : 'linux';
      write(p.join(patchRoot, '$host.patch'), patch);
      write(
        p.join(patchRoot, 'manifest.json'),
        jsonEncode({
          host: {
            'patchSha256': sha256.convert(utf8.encode(patch)).toString(),
            'files': {
              'file': {
                'originalSha256': sha256
                    .convert(utf8.encode('before\n'))
                    .toString(),
                'patchedSha256': sha256
                    .convert(utf8.encode('after\n'))
                    .toString(),
              },
            },
          },
        }),
      );
      final source = write(p.join(context.source, 'file'), 'before\n');
      await context.run('git', ['init'], cwd: context.source);
      await builder.applyPatches();
      expect(source.readAsStringSync(), 'after\n');
      await builder.applyPatches();
      source.writeAsStringSync('unrecognized\n');
      await expectLater(builder.applyPatches(), throwsStateError);
      expect(source.readAsStringSync(), 'unrecognized\n');
      write(p.join(patchRoot, '$host.patch'), 'corrupt');
      await expectLater(builder.applyPatches(), throwsStateError);
    },
  );

  test('rejects mismatched ELF architectures and shared libraries', () {
    final bytes = Uint8List(64)..setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]);
    final data = ByteData.sublistView(bytes)
      ..setUint16(16, 3, Endian.little)
      ..setUint16(18, 62, Endian.little)
      ..setUint64(24, 0x1000, Endian.little);
    expect(inspectSnapshotterHost(bytes, 'linux-x64')['format'], 'ELF');
    expect(
      () => inspectSnapshotterHost(bytes, 'linux-arm64'),
      throwsStateError,
    );
    data.setUint64(24, 0, Endian.little);
    expect(() => inspectSnapshotterHost(bytes, 'linux-x64'), throwsStateError);
    data
      ..setUint16(18, 183, Endian.little)
      ..setUint64(24, 0x1000, Endian.little);
    expect(inspectSnapshotterHost(bytes, 'linux-arm64')['format'], 'ELF');
    expect(
      () => inspectSnapshotterHost(Uint8List(3), 'windows-x64'),
      throwsStateError,
    );
  });

  test('rejects conflicting target macros in transitive runtime compilation', () {
    const command =
        'clang-cl --target=x86_64-pc-windows-msvc -DDART_TARGET_OS_MACOS '
        '-DDART_TARGET_OS_MACOS_IOS -DTARGET_ARCH_ARM64 -DPRODUCT -DDART_PRECOMPILER';
    final entries = [
      for (final file in [
        'bin/gen_snapshot.cc',
        'vm/mach_o.cc',
        'vm/compiler/precompiler.cc',
        'vm/os_win.cc',
        'bin/builtin.cc',
      ])
        {'file': '../../runtime/$file', 'command': command},
    ];
    expect(
      auditSnapshotterCommands(
        entries,
        'windows-x64',
      )['runtimeCompilationUnits'],
      5,
    );
    entries[2]['command'] = '$command -DDART_COMPRESSED_POINTERS';
    expect(
      () => auditSnapshotterCommands(entries, 'windows-x64'),
      throwsStateError,
    );
    entries[2]['command'] = command.replaceAll(
      '-DDART_TARGET_OS_MACOS_IOS',
      '',
    );
    expect(
      () => auditSnapshotterCommands(entries, 'windows-x64'),
      throwsStateError,
    );
  });

  test('rejects Windows DLL and ARM64 files as x64 host tools', () {
    final bytes = Uint8List(128);
    final data = ByteData.sublistView(bytes)
      ..setUint16(0, 0x5a4d, Endian.little)
      ..setUint32(60, 64, Endian.little)
      ..setUint32(64, 0x4550, Endian.little)
      ..setUint16(68, 0x8664, Endian.little)
      ..setUint16(86, 2, Endian.little);
    expect(inspectSnapshotterHost(bytes, 'windows-x64')['format'], 'PE');
    data.setUint16(86, 0x2002, Endian.little);
    expect(
      () => inspectSnapshotterHost(bytes, 'windows-x64'),
      throwsStateError,
    );
    data
      ..setUint16(86, 2, Endian.little)
      ..setUint16(68, 0xaa64, Endian.little);
    expect(
      () => inspectSnapshotterHost(bytes, 'windows-x64'),
      throwsStateError,
    );
  });

  test(
    'checks rpaths, segment sections and signature bounds beyond the loader contract',
    () {
      Uint8List fixture() {
        final bytes = macho.fixture();
        final data = ByteData.sublistView(bytes);
        void u32(int offset, int value) =>
            data.setUint32(offset, value, Endian.little);
        bytes.setRange(512, 544, bytes.sublist(300, 332));
        bytes.setRange(544, 584, bytes.sublist(332, 372));
        bytes.fillRange(232, 400, 0);
        u32(216, 512);
        u32(224, 544);
        u32(16, 8);
        u32(20, 296);
        var offset = 232;
        for (final path in [
          '@executable_path/Frameworks',
          '@loader_path/Frameworks',
        ]) {
          u32(offset, 0x8000001c);
          u32(offset + 4, 40);
          u32(offset + 8, 12);
          bytes.setAll(offset + 12, ascii.encode(path));
          offset += 40;
        }
        u32(312, 0x1d);
        u32(316, 16);
        u32(320, 32000);
        u32(324, 32);
        return bytes;
      }

      expect(
        inspectSnapshotterProduct(fixture(), macho.hash)['rpaths'],
        hasLength(2),
      );
      for (final mutate in <void Function(Uint8List)>[
        (bytes) => bytes[244] = 33,
        (bytes) => bytes[96] = 2,
        (bytes) =>
            ByteData.sublistView(bytes).setUint32(324, 5000, Endian.little),
      ]) {
        final bytes = fixture();
        mutate(bytes);
        expect(
          () => inspectSnapshotterProduct(bytes, macho.hash),
          throwsStateError,
        );
      }
    },
  );
}
