import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/dart_symbol_compatibility.dart';
import 'package:xcross/src/flutter/errors.dart';

Uint8List fixture() {
  final bytes = Uint8List(192);
  final data = ByteData.sublistView(bytes);
  void word(int offset, int value) =>
      data.setUint32(offset, value, Endian.little);
  word(0, 0xfeedfacf);
  word(4, 0x100000c);
  word(12, 10);
  word(16, 2);
  word(20, 96);
  word(32, 0x19);
  word(36, 72);
  bytes.setAll(40, ascii.encode('__LINKEDIT'));
  data.setUint64(72, 128, Endian.little);
  data.setUint64(80, 64, Endian.little);
  word(104, 2);
  word(108, 24);
  word(112, 128);
  word(116, 1);
  word(120, 144);
  word(124, 48);
  word(128, 1);
  bytes[132] = 0x0f;
  data.setUint64(136, 0x4000, Endian.little);
  bytes.setAll(145, ascii.encode('_kDartSnapshotText\u0000'));
  return bytes;
}

void main() {
  test(
    'renames only debug symbol references while preserving addresses and source',
    () {
      final input = fixture();
      final before = Uint8List.fromList(input);
      final result = makeFlutterCompatibleDartSymbols(input);
      final data = ByteData.sublistView(result);
      expect(input, before);
      expect(data.getUint64(136, Endian.little), 0x4000);
      final strings = data.getUint32(120, Endian.little);
      final index = data.getUint32(128, Endian.little);
      expect(
        ascii.decode(result.sublist(strings + index)).split('\u0000').first,
        '_kDartIsolateSnapshotInstructions',
      );
      expect(data.getUint64(80, Endian.little), result.length - 128);
    },
  );

  test(
    'rejects executable input, malformed tables and absent snapshot symbols',
    () {
      for (final offset in [0, 12, 120, 145]) {
        final input = fixture();
        input[offset] = 0;
        expect(
          () => makeFlutterCompatibleDartSymbols(input),
          throwsA(isA<FlutterBuildError>()),
        );
      }
    },
  );
}
