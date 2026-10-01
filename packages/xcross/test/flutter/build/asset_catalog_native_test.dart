import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/resources/asset_catalog_compiler.dart';
import 'package:xcross/src/flutter/build/resources/assetkit_patch.dart';

import '../../../../../tool/ios_resources/asset_catalog.dart';

void main() {
  test('embedded upstream patch retains its exact reviewed bytes', () {
    expect(
      sha256.convert(utf8.encode(assetKitCompatibilityPatch)).toString(),
      assetKitPatchSha256,
    );
  });

  test(
    'native SVG compilation provides three transparent bitmap scales',
    () async {
      final root = await Directory.systemTemp.createTemp('xcross-svg-test-');
      addTearDown(() => root.delete(recursive: true));
      final catalog = Directory(p.join(root.path, 'Test.xcassets'));
      final image = Directory(p.join(catalog.path, 'Symbol.imageset'));
      await image.create(recursive: true);
      await File(p.join(image.path, 'Contents.json')).writeAsString(
        jsonEncode({
          'info': {'version': 1, 'author': 'xcross'},
          'images': [
            {'filename': 'symbol.svg', 'idiom': 'universal'},
          ],
        }),
      );
      await File(p.join(image.path, 'symbol.svg')).writeAsString(
        '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">\n'
        '<rect width="8" height="8" fill="#dc1e32" fill-opacity="0.5"/></svg>',
      );
      final compiler = AssetCatalogCompiler(
        cacheRoot: Platform.environment['XCROSS_ASSETKIT_TEST_CACHE'],
      );
      await compiler.prepare();
      // The compiler changes its subprocess working directory; relative caller
      // paths must still resolve against the original working directory.
      final output = p.relative(p.join(root.path, 'compiled'));
      await compiler.compile([catalog.path], output);
      final audit = AssetCatalog(
        await File(p.join(output, 'Assets.car')).readAsBytes(),
      ).audit();
      expect(audit['lookupMaskErrors'], isEmpty);
      final records = (audit['renditions']! as List<Map<String, Object>>)
          .where((record) => record['pixelFormat'] == 'BGRA')
          .toList();
      expect(records.map((record) => record['scaleFactor']), [100, 200, 300]);
      expect(records.map((record) => record['width']), [8, 16, 24]);
      expect(records.map((record) => record['height']), [8, 16, 24]);
      expect(records.every((record) => record['bitmapFlags'] == 1), isTrue);
    },
    skip: Platform.environment['XCROSS_TEST_ASSETKIT'] != '1'
        ? 'Set XCROSS_TEST_ASSETKIT=1 after xcross setup.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // Fully transparent pixels are covered by the Swift and UIKit probes. These
  // nonzero fixtures also let us inspect the LZFSE raw block without a decoder.
  for (final alpha in [128, 255]) {
    test(
      'native compilation preserves alpha=$alpha, scales, rows and determinism',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'xcross-asset-test-',
        );
        addTearDown(() => root.delete(recursive: true));
        final catalog = Directory(p.join(root.path, 'Test.xcassets'));
        final image = Directory(p.join(catalog.path, 'Marker.imageset'));
        await image.create(recursive: true);
        await File(p.join(catalog.path, 'Contents.json')).writeAsString(
          jsonEncode({
            'info': {'version': 1, 'author': 'test'},
          }),
        );
        await File(p.join(image.path, 'Contents.json')).writeAsString(
          jsonEncode({
            'info': {'version': 1, 'author': 'test'},
            'images': [
              for (final scale in [1, 3])
                {
                  'filename': 'pixel.png',
                  'idiom': 'universal',
                  'scale': '${scale}x',
                },
            ],
          }),
        );
        await File(p.join(image.path, 'pixel.png')).writeAsBytes(
          base64Decode(
            {
              128:
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGO4I2fUAAAEswGtWBoc4gAAAABJRU5ErkJggg==',
              255:
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGO4I2f0HwAFMgIsjP5jlwAAAABJRU5ErkJggg==',
            }[alpha]!,
          ),
        );
        final compiler = AssetCatalogCompiler(
          cacheRoot: Platform.environment['XCROSS_ASSETKIT_TEST_CACHE'],
        );
        await compiler.prepare();
        final first = p.join(root.path, 'first');
        final second = p.join(root.path, 'second');
        await compiler.compile([catalog.path], first);
        await compiler.compile([catalog.path], second);
        final bytes = await File(p.join(first, 'Assets.car')).readAsBytes();
        expect(bytes, await File(p.join(second, 'Assets.car')).readAsBytes());
        expect(_availability(bytes)[12], 0x0a);
        _expectPaddedPixels(bytes, alpha);
      },
      skip: Platform.environment['XCROSS_TEST_ASSETKIT'] != '1'
          ? 'Set XCROSS_TEST_ASSETKIT=1 with native Swift and Git installed.'
          : false,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}

// Inspect the actual compiler output independently of the embedded Swift tests.
// This 1x1 fixture uses LZFSE's raw-block envelope, so no host decoder is needed.
void _expectPaddedPixels(Uint8List bytes, int alpha) {
  int u32(Uint8List data, int offset, [Endian endian = Endian.little]) =>
      ByteData.sublistView(data).getUint32(offset, endian);
  final index = u32(bytes, 16, Endian.big);
  var records = 0;
  for (var id = 0; id < u32(bytes, index, Endian.big); id++) {
    final entry = index + 4 + id * 8;
    final start = u32(bytes, entry, Endian.big);
    final size = u32(bytes, entry + 4, Endian.big);
    if (size < 184 ||
        ascii.decode(bytes.sublist(start, start + 4), allowInvalid: true) !=
            'ISTC') {
      continue;
    }
    final data = Uint8List.sublistView(bytes, start, start + size);
    expect(u32(data, 12), 1);
    expect(u32(data, 16), 1);
    final body = 184 + u32(data, 168);
    var pos = 184;
    var stride = 0;
    while (pos < body) {
      if (u32(data, pos) == 1007) stride = u32(data, pos + 8);
      pos += 8 + u32(data, pos + 4);
    }
    expect(stride, 16);
    expect(ascii.decode(data.sublist(body, body + 4)), 'MLEC');
    expect(u32(data, body + 4), alpha == 255 ? 3 : 1);
    expect(u32(data, body + 8), 4); // KCBC/LZFSE codec.
    final chunk = body + 16;
    expect(ascii.decode(data.sublist(chunk, chunk + 4)), 'KCBC');
    expect(u32(data, chunk + 12), 1); // One row.
    final payload = chunk + 20;
    expect(ascii.decode(data.sublist(payload, payload + 4)), 'bvx-');
    final decodedLength = u32(data, payload + 4);
    expect(decodedLength, stride);
    expect(data.sublist(payload + 8, payload + 8 + decodedLength), [
      for (final component in [50, 30, 220]) (component * alpha + 127) ~/ 255,
      alpha, // Premultiplied BGRA pixel, with source alpha preserved.
      ...List<int>.filled(12, 0),
    ]);
    expect(
      ascii.decode(
        data.sublist(payload + 8 + decodedLength, payload + 12 + decodedLength),
      ),
      r'bvx$',
    );
    records++;
  }
  expect(records, 2); // Both requested scale variants are checked.
}

// Independent inspection of the one-asset fixture's serialized lookup table.
Map<int, int> _availability(Uint8List bytes) {
  int u32(Uint8List data, int offset, [Endian endian = Endian.little]) =>
      ByteData.sublistView(data).getUint32(offset, endian);
  final index = u32(bytes, 16, Endian.big);
  Uint8List block(int id) {
    final entry = index + 4 + id * 8;
    final start = u32(bytes, entry, Endian.big);
    return Uint8List.sublistView(
      bytes,
      start,
      start + u32(bytes, entry + 4, Endian.big),
    );
  }

  var pos = u32(bytes, 24, Endian.big);
  final count = u32(bytes, pos, Endian.big);
  pos += 4;
  final variables = <String, int>{};
  for (var i = 0; i < count; i++) {
    final size = bytes[pos + 4];
    variables[utf8.decode(bytes.sublist(pos + 5, pos + 5 + size))] = u32(
      bytes,
      pos,
      Endian.big,
    );
    pos += 5 + size;
  }
  final format = block(variables['KEYFORMAT']!);
  final tree = block(variables['BITMAPKEYS']!);
  final leaf = block(u32(tree, 8, Endian.big));
  final descriptor = block(u32(leaf, 12, Endian.big));
  return {
    for (var i = 0; i < u32(format, 8); i++)
      u32(format, 12 + i * 4): u32(descriptor, 16 + i * 4),
  };
}
