// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Synthetic catalogs covering scale, device, appearance, color and alpha.
Future<Map<String, Object>> writeAssetCatalogFixtures(
  String destination,
) async {
  const info = {'version': 1, 'author': 'xcross'};
  final specs = <String, List<(int, int, String, bool)>>{
    'Single1': [(1, 8, 'universal', false)],
    'Tiny1': [(1, 1, 'universal', false)],
    'Single2': [(2, 8, 'universal', false)],
    'Single3': [(3, 8, 'universal', false)],
    'Scaled': [for (var s = 1; s <= 3; s++) (s, s * 8, 'universal', false)],
    'EqualPixels': [for (var s = 1; s <= 3; s++) (s, 24, 'universal', false)],
    'AlphaVariants': [
      for (var s = 1; s <= 3; s++) (s, s * 8, 'universal', false),
    ],
    'DeviceVariants': [
      for (final idiom in ['iphone', 'ipad']) (2, 16, idiom, false),
    ],
    'DarkVariant': [
      for (final dark in [false, true]) (2, 16, 'universal', dark),
    ],
  };
  for (final name in ['Minimal', 'Matrix', 'Integration']) {
    final catalog = p.join(destination, '$name.xcassets');
    await _writeJson(p.join(catalog, 'Contents.json'), {'info': info});
    final assets = name == 'Minimal' ? {'Single1': specs['Single1']!} : specs;
    for (final asset in assets.entries) {
      final images = <Map<String, Object>>[];
      final imageSet = p.join(catalog, '${asset.key}.imageset');
      await Directory(imageSet).create(recursive: true);
      for (var i = 0; i < asset.value.length; i++) {
        final (scale, size, idiom, dark) = asset.value[i];
        final filename = 'variant$i.png';
        final rgb = dark
            ? [80, 50, 100]
            : switch (scale) {
                1 => [220, 30, 50],
                2 => [20, 180, 70],
                _ => [30, 60, 220],
              };
        final alpha = asset.key == 'AlphaVariants'
            ? [0, 128, 255][scale - 1]
            : 255;
        await File(
          p.join(imageSet, filename),
        ).writeAsBytes(_png(size, [...rgb, alpha]));
        images.add({
          'filename': filename,
          'idiom': idiom,
          'scale': '${scale}x',
          if (dark)
            'appearances': [
              {'appearance': 'luminosity', 'value': 'dark'},
            ],
        });
      }
      await _writeJson(p.join(imageSet, 'Contents.json'), {
        'info': info,
        'images': images,
      });
    }
    if (name == 'Integration') {
      await _writeJson(p.join(catalog, 'Accent.colorset', 'Contents.json'), {
        'info': info,
        'colors': [
          {
            'idiom': 'universal',
            'color': {
              'color-space': 'srgb',
              'components': {
                'red': '0.1',
                'green': '0.4',
                'blue': '0.8',
                'alpha': '1.0',
              },
            },
          },
        ],
      });
      final icons = <Map<String, String>>[];
      final iconSet = p.join(catalog, 'AppIcon.appiconset');
      await Directory(iconSet).create(recursive: true);
      for (final scale in [2, 3]) {
        final filename = 'icon$scale.png';
        await File(
          p.join(iconSet, filename),
        ).writeAsBytes(_png(60 * scale, [20, 150, 80, 255]));
        icons.add({
          'filename': filename,
          'idiom': 'iphone',
          'size': '60x60',
          'scale': '${scale}x',
        });
      }
      await _writeJson(p.join(iconSet, 'Contents.json'), {
        'info': info,
        'images': icons,
      });
    }
  }
  return {
    for (final asset in specs.entries)
      asset.key: [
        for (final (scale, size, idiom, dark) in asset.value)
          [scale, size, idiom, dark],
      ],
  };
}

Future<void> _writeJson(String path, Object data) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(data)}\n',
  );
}

Uint8List _png(int size, List<int> rgba) {
  final header = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final pixels = BytesBuilder();
  for (var y = 0; y < size; y++) {
    pixels.addByte(0);
    for (var x = 0; x < size; x++) {
      pixels.add(rgba);
    }
  }
  final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String name, List<int> bytes) {
    final data = [...ascii.encode(name), ...bytes];
    output
      ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
      ..add(data)
      ..add((ByteData(4)..setUint32(0, getCrc32(data))).buffer.asUint8List());
  }

  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', const ZLibEncoder().encode(pixels.takeBytes()));
  chunk('IEND', []);
  return output.takeBytes();
}
