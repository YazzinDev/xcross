import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/build_lock.dart';
import 'package:xcross/src/update/internal/archive_entry_path.dart';

import 'snapshotter_source_archive.dart';

String snapshotterHost([Abi? abi]) => switch (abi ?? Abi.current()) {
  Abi.windowsX64 => 'windows-x64',
  Abi.linuxX64 => 'linux-x64',
  Abi.linuxArm64 => 'linux-arm64',
  _ => throw UnsupportedError('Build hosts: Windows x64, Linux x64/ARM64'),
};

String findSnapshotterRepository() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File(
      p.join(directory.path, 'tool', 'ios_aot', 'versions.json'),
    ).existsSync()) {
      return directory.path;
    }
    if (p.equals(directory.path, directory.parent.path)) {
      throw StateError('Run this tool inside the xcross repository.');
    }
    directory = directory.parent;
  }
}

Future<String> fileSha256(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Map<String, dynamic> readObject(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// Private, host-specific build state. No installed Flutter SDK is patched.
final class SnapshotterContext {
  SnapshotterContext(String repository, {String? cacheRoot, String? host})
    : repository = p.normalize(p.absolute(repository)),
      host = host ?? snapshotterHost() {
    recipe = p.join(this.repository, 'tool', 'ios_aot');
    pins = readObject(p.join(recipe, 'versions.json'));
    cache = p.normalize(
      p.absolute(
        cacheRoot ??
            p.joinAll([
              this.repository,
              'build',
              'ios-aot',
              if (this.host != 'windows-x64') this.host,
            ]),
      ),
    );
    if (!p.isWithin(p.join(this.repository, 'build'), cache)) {
      throw ArgumentError('Snapshotter caches must stay under xcross/build.');
    }
    source = p.join(cache, 'sdk-${pins['dartRevision']}');
  }

  final String repository;
  final String host;
  late final String recipe;
  late final String cache;
  late final String source;
  late final Map<String, dynamic> pins;
  bool get windows => host == 'windows-x64';
  String get suffix => windows ? '.exe' : '';
  String get target => 'gen_snapshot_product_ios_arm64';

  Future<T> locked<T>(Future<T> Function() action) async {
    final lock = p.join(cache, 'snapshotter-build.lock');
    await assertPrivate(lock);
    return withBuildLock(lock, action);
  }

  /// Reject links before changing files, including Windows directory junctions.
  /// Dart's FileStat omits link counts, so use the host's read-only file query.
  Future<void> assertPrivate(String path) async {
    final absolute = p.normalize(p.absolute(path));
    if (!p.equals(cache, absolute) && !p.isWithin(cache, absolute)) {
      throw StateError('Path escapes the xcross cache: $path');
    }
    var parent = absolute;
    while (true) {
      final type = FileSystemEntity.typeSync(parent, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('Refusing linked path: $parent');
      }
      if (type != FileSystemEntityType.notFound) {
        final resolved = File(parent).resolveSymbolicLinksSync();
        if (!p.equals(p.normalize(resolved), parent)) {
          throw StateError('Refusing reparse point or linked path: $parent');
        }
      }
      if (p.equals(parent, repository)) break;
      final next = p.dirname(parent);
      if (p.equals(next, parent)) throw StateError('Cache outside repository');
      parent = next;
    }
    if (FileSystemEntity.typeSync(absolute) == FileSystemEntityType.file) {
      final result = await Process.run(
        Platform.isWindows ? 'fsutil.exe' : 'stat',
        Platform.isWindows
            ? ['hardlink', 'list', absolute]
            : ['-c', '%h', '--', absolute],
      );
      if (result.exitCode != 0) {
        throw StateError(
          'Cannot verify private file $absolute: ${result.stderr}',
        );
      }
      final output = '${result.stdout}'.trim();
      final links = Platform.isWindows
          ? const LineSplitter()
                .convert(output)
                .where((line) => line.trim().startsWith(r'\'))
                .length
          : int.parse(output);
      if (links != 1) throw StateError('Refusing hardlinked file: $absolute');
    }
  }

  Future<void> write(String path, List<int> bytes) async {
    await assertPrivate(path);
    final pending = '$path.part';
    await assertPrivate(pending);
    await File(path).parent.create(recursive: true);
    await File(pending).writeAsBytes(bytes, flush: true);
    await File(pending).rename(path);
  }

  Future<void> writeText(String path, String contents) =>
      write(path, utf8.encode(contents));

  Future<void> writeJson(String path, Object value) =>
      writeText(path, '${const JsonEncoder.withIndent('  ').convert(value)}\n');

  Future<String> download(String name) async {
    final downloads = pins['downloads'] as Map<String, dynamic>;
    final spec = downloads[name] as Map<String, dynamic>;
    final sourceArchive = spec.containsKey('tarContentsSha256');
    final expected = spec[sourceArchive ? 'tarContentsSha256' : 'sha256'];
    final target = p.join(cache, 'downloads', name);
    await assertPrivate(target);
    if (!File(target).existsSync()) {
      final pending = '$target.part';
      await assertPrivate(pending);
      await File(target).parent.create(recursive: true);
      stdout.writeln('Downloading ${spec['url']}');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 120);
      try {
        final request = await client.getUrl(Uri.parse(spec['url'] as String));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(
            'Download failed: HTTP ${response.statusCode}',
            uri: request.uri,
          );
        }
        final sink = File(pending).openWrite();
        try {
          await sink.addStream(response.timeout(const Duration(seconds: 120)));
        } finally {
          await sink.close();
        }
        if (await _downloadChecksum(pending, sourceArchive) != expected) {
          throw StateError('Download checksum mismatch: $name');
        }
        await File(pending).rename(target);
      } finally {
        client.close(force: true);
      }
    }
    if (await _downloadChecksum(target, sourceArchive) != expected) {
      throw StateError('Cached download checksum mismatch: $name');
    }
    return target;
  }

  Future<String> _downloadChecksum(String path, bool sourceArchive) async {
    if (!sourceArchive) return fileSha256(path);
    // These archives are large. Expand to a private temporary file so hashing
    // does not retain the entire decompressed tar in memory.
    final stage = await Directory(cache).createTemp('.source-check-');
    InputFileStream? input;
    try {
      final tar = p.join(stage.path, 'source.tar');
      final compressed = InputFileStream(path);
      final expanded = OutputFileStream(tar);
      try {
        const GZipDecoder().decodeStream(compressed, expanded);
      } finally {
        await compressed.close();
        await expanded.close();
      }
      input = InputFileStream(tar);
      return snapshotterSourceArchiveSha256(input);
    } finally {
      await input?.close();
      await stage.delete(recursive: true);
    }
  }

  /// Extract into a private staging tree, preserving executable bits on Linux.
  /// Source archives are large; stream the tar instead of retaining it in RAM.
  Future<void> extract(
    String archive,
    String destination, {
    String? memberRoot,
    bool skipSymbolicLinks = false,
  }) async {
    await assertPrivate(destination);
    await Directory(p.dirname(destination)).create(recursive: true);
    final stage = await Directory(
      p.dirname(destination),
    ).createTemp('.extract-');
    final previous = '${stage.path}.previous';
    final tarPath = '${stage.path}.tar';
    InputFileStream? input;
    var movedPrevious = false;
    try {
      var decodedPath = archive;
      if (archive.endsWith('.tar.gz')) {
        final compressed = InputFileStream(archive);
        final expanded = OutputFileStream(tarPath);
        try {
          const GZipDecoder().decodeStream(compressed, expanded);
        } finally {
          await compressed.close();
          await expanded.close();
        }
        decodedPath = tarPath;
      }
      input = InputFileStream(decodedPath);
      final decoded = archive.endsWith('.zip')
          ? ZipDecoder().decodeStream(input)
          : TarDecoder().decodeStream(input);
      final executables = <String>[];
      for (final entry in decoded) {
        if (entry.isDirectory && p.normalize(entry.name) == '.') continue;
        final target = ArchiveEntryPath.resolve(stage.path, entry.name);
        if (target == null) {
          throw StateError('Unsafe archive entry: ${entry.name}');
        }
        if (entry.isSymbolicLink) {
          if (skipSymbolicLinks) continue;
          throw StateError('Unsafe archive entry: ${entry.name}');
        }
        if (entry.isDirectory) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await File(target).parent.create(recursive: true);
        final output = OutputFileStream(target);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        if (entry.mode & 0x49 != 0) executables.add(target);
      }
      await input.close();
      input = null;
      if (!Platform.isWindows) {
        for (var i = 0; i < executables.length; i += 64) {
          await run('chmod', ['755', '--', ...executables.skip(i).take(64)]);
        }
      }
      final tree = Directory(
        memberRoot == null ? stage.path : p.join(stage.path, memberRoot),
      );
      if (!p.equals(tree.path, stage.path) &&
          !p.isWithin(stage.path, tree.path)) {
        throw ArgumentError('Archive member root escapes staging');
      }
      if (!tree.existsSync()) {
        throw StateError('Archive root missing: $memberRoot');
      }
      if (Directory(destination).existsSync()) {
        await _renameTree(Directory(destination), previous);
        movedPrevious = true;
      }
      try {
        await _renameTree(tree, destination);
      } on Object {
        if (movedPrevious) await _renameTree(Directory(previous), destination);
        rethrow;
      }
      if (movedPrevious) await Directory(previous).delete(recursive: true);
    } finally {
      await input?.close();
      if (stage.existsSync()) await stage.delete(recursive: true);
      if (File(tarPath).existsSync()) await File(tarPath).delete();
    }
  }

  Future<void> _renameTree(Directory source, String destination) async {
    // Windows indexers can briefly retain a freshly extracted directory. Retry
    // only access/sharing violations; never turn a failed rename into a copy.
    for (var attempt = 0; ; attempt++) {
      try {
        await source.rename(destination);
        return;
      } on FileSystemException catch (error) {
        if (!Platform.isWindows ||
            attempt == 5 ||
            !{5, 32, 33}.contains(error.osError?.errorCode)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 100 << attempt));
      }
    }
  }

  Future<void> executable(String path) async {
    await assertPrivate(path);
    if (!Platform.isWindows) await run('chmod', ['755', '--', path]);
  }

  Future<String> run(
    String executable,
    List<String> arguments, {
    String? cwd,
    Map<String, String>? environment,
    String? log,
  }) async {
    if (log == null) {
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: cwd ?? repository,
        environment: environment,
      );
      if (result.exitCode != 0) {
        throw ProcessException(
          executable,
          arguments,
          '${result.stdout}\n${result.stderr}',
          result.exitCode,
        );
      }
      return '${result.stdout}${result.stderr}'.trim();
    }
    await assertPrivate(log);
    stdout.writeln('Running ${p.basename(executable)}; log: $log');
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: cwd ?? repository,
      environment: environment,
    );
    final sink = File(log).openWrite();
    // Both streams must be drained while a compiler is running.
    final outDone = process.stdout.forEach(sink.add);
    final errDone = process.stderr.forEach(sink.add);
    try {
      final result = await process.exitCode;
      await Future.wait([outDone, errDone]);
      await sink.flush();
      if (result != 0) {
        final text = await File(log).readAsString();
        final tail = text.length > 12000
            ? text.substring(text.length - 12000)
            : text;
        throw ProcessException(executable, arguments, tail, result);
      }
      return '';
    } finally {
      await sink.close();
    }
  }
}
