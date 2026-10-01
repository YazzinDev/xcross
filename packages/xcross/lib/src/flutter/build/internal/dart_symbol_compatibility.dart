import 'dart:convert';
import 'dart:typed_data';

import 'package:xcross/src/flutter/errors.dart';

/// Adapt only a debug-only MH_DSYM to native_stack_traces 0.6.1's old symbol
/// contract. The engine continues to load the unchanged kDartSnapshotText.
/// Keep the original symbols too; remove this adapter when the pinned decoder
/// understands the unified snapshot text symbol.
Uint8List makeFlutterCompatibleDartSymbols(Uint8List original) {
  final bytes = Uint8List.fromList(original);
  final data = ByteData.sublistView(bytes);
  Never fail() =>
      throw FlutterBuildError('Unsupported Dart split-symbol Mach-O layout.');
  void bounds(int offset, int size) {
    if (offset < 0 || size < 0 || offset + size > bytes.length) fail();
  }

  int u32(int offset) {
    bounds(offset, 4);
    return data.getUint32(offset, Endian.little);
  }

  int u64(int offset) {
    bounds(offset, 8);
    return data.getUint64(offset, Endian.little);
  }

  bounds(0, 32);
  if (u32(0) != 0xfeedfacf || u32(4) != 0x100000c || u32(12) != 10) fail();
  final end = 32 + u32(20);
  bounds(32, u32(20));
  int? table;
  int? linkedit;
  var at = 32;
  for (var i = 0; i < u32(16); i++) {
    final command = u32(at);
    final size = u32(at + 4);
    if (size < 8 || at + size > end) fail();
    if (command == 2) {
      if (size != 24 || table != null) fail();
      table = at;
    }
    if (command == 0x1d) fail(); // Never rewrite signed/executable code.
    if (command == 0x19 &&
        size >= 72 &&
        ascii.decode(bytes.sublist(at + 8, at + 24)).split('\u0000').first ==
            '__LINKEDIT') {
      if (linkedit != null) fail();
      linkedit = at;
    }
    at += size;
  }
  if (table == null || linkedit == null || at != end) fail();
  final symbols = u32(table + 8);
  final count = u32(table + 12);
  final strings = u32(table + 16);
  final stringSize = u32(table + 20);
  if (symbols < end || strings < symbols + count * 16) fail();
  bounds(symbols, count * 16);
  bounds(strings, stringSize);
  var renamed = 0;
  for (var i = 0; i < count; i++) {
    final entry = symbols + i * 16;
    final index = u32(entry);
    if (index >= stringSize) fail();
    final terminator = bytes.indexOf(0, strings + index);
    if (terminator < 0 || terminator >= strings + stringSize) fail();
    final name = utf8.decode(bytes.sublist(strings + index, terminator));
    if (name == '_kDartSnapshotText') {
      data.setUint32(entry, stringSize, Endian.little);
      renamed++;
    }
  }
  if (renamed == 0) fail();
  final text = [
    ...original.sublist(strings, strings + stringSize),
    ...ascii.encode('_kDartIsolateSnapshotInstructions\u0000'),
  ];
  final offset = bytes.length;
  data.setUint32(table + 16, offset, Endian.little);
  data.setUint32(table + 20, text.length, Endian.little);
  final fileOffset = u64(linkedit + 40);
  bounds(fileOffset, u64(linkedit + 48));
  final length = offset + text.length - fileOffset;
  data.setUint64(linkedit + 48, length, Endian.little);
  data.setUint64(
    linkedit + 32,
    (length + 16383) ~/ 16384 * 16384,
    Endian.little,
  );
  return Uint8List.fromList([...bytes, ...text]);
}
