import 'dart:convert';
import 'dart:typed_data';

import 'package:xcross/src/flutter/errors.dart';

/// Validates the loader contract, rather than mistaking any ARM64 binary for
/// Flutter AOT. Signing and actual device execution remain separate checks.
Map<String, Object> inspectIosAotArtifact(
  Uint8List bytes, {
  required String snapshotHash,
  required String minimumOS,
}) {
  Never invalid(String message) =>
      throw FlutterBuildError('Invalid iOS AOT App.framework: $message');
  // Positional condition mirrors assert/expect for parser invariants.
  // ignore: avoid_positional_boolean_parameters
  void require(bool value, String message) {
    if (!value) invalid(message);
  }

  final data = ByteData.sublistView(bytes);
  int u32(int offset) {
    require(offset >= 0 && offset + 4 <= bytes.length, 'truncated integer');
    return data.getUint32(offset, Endian.little);
  }

  int u64(int offset) {
    require(offset >= 0 && offset + 8 <= bytes.length, 'truncated address');
    return data.getUint64(offset, Endian.little);
  }

  String string(int offset, int end) {
    require(
      offset >= 0 && offset < end && end <= bytes.length,
      'string outside file',
    );
    var zero = offset;
    while (zero < end && bytes[zero] != 0) {
      zero++;
    }
    require(zero < end, 'unterminated string');
    return utf8.decode(bytes.sublist(offset, zero));
  }

  require(
    u32(0) == 0xfeedfacf && u32(4) == 0x100000c && u32(8) == 0 && u32(12) == 6,
    'expected a thin ARM64 Mach-O dylib',
  );
  final commandEnd = 32 + u32(20);
  require(commandEnd <= bytes.length, 'load commands outside file');
  final segments = <({int address, int offset, int size})>[];
  ({int symbols, int count, int strings, int length})? symtab;
  int? platform;
  int? minos;
  String? installName;
  String? uuid;
  var offset = 32;
  for (var index = 0; index < u32(16); index++) {
    require(offset + 8 <= commandEnd, 'truncated load command');
    final command = u32(offset);
    final size = u32(offset + 4);
    final end = offset + size;
    require(
      size >= 8 && size % 8 == 0 && end <= commandEnd,
      'invalid load command size',
    );
    if (command == 0x19) {
      require(size >= 72, 'truncated segment');
      final address = u64(offset + 24);
      final fileoff = u64(offset + 40);
      final filesize = u64(offset + 48);
      require(
        fileoff + filesize <= bytes.length && filesize <= u64(offset + 32),
        'segment outside file',
      );
      require(
        address % 16384 == 0 && fileoff % 16384 == 0,
        'segment not 16 KiB aligned',
      );
      require(u32(offset + 60) & 6 != 6, 'writable executable segment');
      segments.add((address: address, offset: fileoff, size: filesize));
    } else if (command == 0x32) {
      require(size >= 24, 'truncated platform');
      platform = u32(offset + 8);
      minos = u32(offset + 12);
    } else if (command == 0xd) {
      require(size >= 24, 'truncated install name');
      installName = string(offset + u32(offset + 8), end);
    } else if (command == 0x1b) {
      require(size == 24, 'invalid UUID');
      uuid = bytes
          .sublist(offset + 8, end)
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
    } else if (command == 2) {
      require(size == 24, 'invalid symbol table');
      symtab = (
        symbols: u32(offset + 8),
        count: u32(offset + 12),
        strings: u32(offset + 16),
        length: u32(offset + 20),
      );
    }
    offset = end;
  }
  require(offset == commandEnd, 'load command count mismatch');
  final version = minimumOS.split('.').map(int.parse).toList();
  final encodedVersion =
      (version[0] << 16) |
      ((version.length > 1 ? version[1] : 0) << 8) |
      (version.length > 2 ? version[2] : 0);
  require(
    platform == 2 && minos == encodedVersion,
    'wrong iOS platform or deployment target',
  );
  require(
    installName == '@rpath/App.framework/App' && uuid != null,
    'missing loader identity',
  );
  if (symtab == null) invalid('missing symbol table');
  final table = symtab;
  require(
    table.symbols + table.count * 16 <= bytes.length &&
        table.strings + table.length <= bytes.length,
    'symbol table outside file',
  );
  final symbols = <String, int>{};
  for (var index = 0; index < table.count; index++) {
    final at = table.symbols + index * 16;
    final type = bytes[at + 4];
    if (type & 0xe0 == 0 && type & 0xf == 0xf) {
      symbols[string(table.strings + u32(at), table.strings + table.length)] =
          u64(at + 8);
    }
  }
  require(
    symbols.containsKey('_kDartSnapshotData') &&
        symbols.containsKey('_kDartSnapshotText'),
    'missing Dart snapshot exports',
  );
  final address = symbols['_kDartSnapshotData']!;
  final mappings = segments
      .where(
        (segment) =>
            address >= segment.address &&
            address < segment.address + segment.size,
      )
      .toList();
  require(mappings.length == 1, 'snapshot data does not map to one segment');
  final segment = mappings.single;
  final start = address - segment.address + segment.offset;
  require(
    u32(start) == 0xdcdcf5f5 && u64(start + 12) == 2,
    'not a Dart full-AOT snapshot',
  );
  final length = u64(start + 4);
  require(
    length >= 52 && start + length + 4 <= segment.offset + segment.size,
    'truncated snapshot',
  );
  require(
    ascii.decode(bytes.sublist(start + 20, start + 52)) == snapshotHash,
    'Dart snapshot version mismatch',
  );
  final features = string(start + 52, start + length + 4);
  final flags = features.split(' ').toSet();
  require(
    flags.containsAll({'product', 'arm64', 'ios', 'no-compressed-pointers'}) &&
        flags.intersection({
          'debug',
          'release',
          'android',
          'windows',
          'compressed-pointers',
        }).isEmpty,
    'incorrect snapshot target features',
  );
  return {
    'cpu': 'arm64',
    'platform': platform!,
    'snapshotHash': snapshotHash,
    'features': features,
    'uuid': uuid!,
  };
}
