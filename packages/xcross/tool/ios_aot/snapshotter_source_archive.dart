import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:xcross/src/update/internal/archive_entry_path.dart';

/// SHA-256 of sorted [path, type, permissions, content SHA-256] records.
/// Gitiles regenerates tar timestamps for the same commit. Bind source archives
/// to their complete contents instead of compression, timestamps or ownership.
String snapshotterSourceArchiveSha256(InputStream input) {
  final records = <String, List<Object>>{};
  final decoder = TarDecoder();
  decoder.decodeStream(
    input,
    verify: true,
    callback: (entry) {
      if (entry.isDirectory && entry.name == './') return;
      final path = ArchiveEntryPath.sanitize(entry.name);
      if (path == null || entry.isSymbolicLink || records.containsKey(path)) {
        throw StateError(
          'Unsafe or duplicate source archive entry: ${entry.name}',
        );
      }
      final type = entry.isDirectory ? 'directory' : 'file';
      final content = entry.isDirectory
          ? ''
          : sha256.convert(entry.content).toString();
      records[path] = [path, type, entry.mode & 0xfff, content];
      // Keep only the manifest in memory, not all of ICU's file contents.
      entry.clear();
    },
  );
  for (final entry in decoder.files) {
    if (!{'', '0', '5'}.contains(entry.typeFlag)) {
      throw StateError('Unsupported source archive entry: ${entry.filename}');
    }
  }
  if (records.isEmpty) throw StateError('Empty source archive');
  final paths = records.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(jsonEncode([for (final path in paths) records[path]])),
      )
      .toString();
}
