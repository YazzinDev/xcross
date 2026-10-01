import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/ios_aot_artifact.dart';
import 'package:xcross/src/flutter/errors.dart';

const hash = '0123456789abcdef0123456789abcdef';

// Synthetic container for negative parser tests, never an executable fixture.
Uint8List fixture() {
  final bytes = Uint8List(32768);
  final data = ByteData.sublistView(bytes);
  void u32(int at, int value) => data.setUint32(at, value, Endian.little);
  void u64(int at, int value) => data.setUint64(at, value, Endian.little);
  void string(int at, String value) =>
      bytes.setRange(at, at + value.length, ascii.encode(value));
  u32(0, 0xfeedfacf);
  u32(4, 0x100000c);
  u32(12, 6);
  u32(16, 5);
  u32(20, 200);
  u32(32, 0x19);
  u32(36, 72);
  u64(64, 32768);
  u64(80, 32768);
  u32(92, 5);
  u32(104, 0x32);
  u32(108, 24);
  u32(112, 2);
  u32(116, 13 << 16);
  u32(128, 0xd);
  u32(132, 56);
  u32(136, 24);
  string(152, '@rpath/App.framework/App');
  u32(184, 0x1b);
  u32(188, 24);
  u32(208, 2);
  u32(212, 24);
  u32(216, 300);
  u32(220, 2);
  u32(224, 332);
  u32(228, 40);
  const symbols = '\u0000_kDartSnapshotData\u0000_kDartSnapshotText\u0000';
  string(332, symbols);
  u32(300, 1);
  bytes[304] = 0xf;
  u64(308, 4096);
  u32(316, 20);
  bytes[320] = 0xf;
  u64(324, 16384);
  u32(4096, 0xdcdcf5f5);
  u64(4100, 256);
  u64(4108, 2);
  string(4116, hash);
  string(4148, 'product arm64 ios no-compressed-pointers');
  return bytes;
}

void main() {
  Map<String, Object> inspect(Uint8List bytes) =>
      inspectIosAotArtifact(bytes, snapshotHash: hash, minimumOS: '13.0');
  test('accepts the product iOS loader contract', () {
    expect(
      inspect(fixture())['features'],
      'product arm64 ios no-compressed-pointers',
    );
  });
  test(
    'rejects simulator, JIT, missing exports, and wrong snapshot versions',
    () {
      for (final mutation in <void Function(Uint8List)>[
        (bytes) => bytes[112] = 7,
        (bytes) => bytes[112] = 1,
        (bytes) => bytes[4108] = 1,
        (bytes) => bytes[320] = 0,
        (bytes) => bytes[4116] = 120,
        (bytes) => bytes[4148] = 120,
      ]) {
        final bytes = fixture();
        mutation(bytes);
        expect(() => inspect(bytes), throwsA(isA<FlutterBuildError>()));
      }
    },
  );
  test('rejects Android, debug and compressed-pointer snapshots', () {
    for (final features in [
      'product arm64 android no-compressed-pointers',
      'debug arm64 ios no-compressed-pointers',
      'product arm64 ios compressed-pointers',
    ]) {
      final bytes = fixture()..fillRange(4148, 4250, 0);
      bytes.setAll(4148, ascii.encode(features));
      expect(() => inspect(bytes), throwsA(isA<FlutterBuildError>()));
    }
  });
  test('rejects truncated and non-Mach-O files', () {
    expect(() => inspect(Uint8List(64)), throwsA(isA<FlutterBuildError>()));
    expect(
      () => inspect(fixture().sublist(0, 100)),
      throwsA(isA<FlutterBuildError>()),
    );
  });
}
