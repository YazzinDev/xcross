// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Independent BOM/CAR metadata reader for compiler diagnostics.
/// Pixel decoding and UIKit rendering remain separate validation gates.
final class AssetCatalog {
  AssetCatalog(this.bytes) {
    if (ascii.decode(_slice(bytes, 0, 8)) != 'BOMStore') {
      throw const FormatException('Not a BOM catalog');
    }
    _index = _u32(bytes, 16, Endian.big);
    var position = _u32(bytes, 24, Endian.big);
    final count = _u32(bytes, position, Endian.big);
    position += 4;
    for (var i = 0; i < count; i++) {
      final block = _u32(bytes, position, Endian.big);
      final length = _slice(bytes, position + 4, 1).single;
      _variables[_string(_slice(bytes, position + 5, length))] = block;
      position += 5 + length;
    }
  }

  final Uint8List bytes;
  late final int _index;
  final _variables = <String, int>{};

  Uint8List _block(int id) {
    if (id >= _u32(bytes, _index, Endian.big)) {
      throw const FormatException('Invalid BOM block identifier');
    }
    final offset = _index + 4 + id * 8;
    return _slice(
      bytes,
      _u32(bytes, offset, Endian.big),
      _u32(bytes, offset + 4, Endian.big),
    );
  }

  Uint8List _variable(String name) {
    final id = _variables[name];
    if (id == null) throw FormatException('Missing BOM variable: $name');
    return _block(id);
  }

  List<(Object, Uint8List)> _tree(String name, {bool inlineKeys = false}) {
    if (!_variables.containsKey(name)) return [];
    final visited = <int>{};
    final entries = <(Object, Uint8List)>[];
    final pending = [_u32(_variable(name), 8, Endian.big)];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      if (!visited.add(id)) throw const FormatException('Cycle in BOM tree');
      final node = _block(id);
      final leaf = _u16(node, 0, Endian.big);
      final count = _u16(node, 2, Endian.big);
      final children = <int>[];
      for (var i = 0; i < count; i++) {
        final value = _u32(node, 12 + 8 * i, Endian.big);
        final key = _u32(node, 16 + 8 * i, Endian.big);
        if (leaf != 0) {
          entries.add((inlineKeys ? key : _block(key), _block(value)));
        } else {
          children.add(value);
        }
      }
      pending.addAll(children.reversed);
    }
    return entries;
  }

  Map<String, Object> audit() {
    final keyFormat = _variable('KEYFORMAT');
    final attributes = [
      for (var i = 0; i < _u32(keyFormat, 8); i++) _u32(keyFormat, 12 + i * 4),
    ];
    final facets = <int, String>{};
    for (final (key, value) in _tree('FACETKEYS')) {
      for (var i = 0; i < _u16(value, 4); i++) {
        if (_u16(value, 6 + i * 4) == 17) {
          facets[_u16(value, 8 + i * 4)] = _string(key as Uint8List);
        }
      }
    }
    final descriptors = Map<Object, Uint8List>.fromEntries(
      _tree(
        'BITMAPKEYS',
        inlineKeys: true,
      ).map((entry) => MapEntry(entry.$1, entry.$2)),
    );
    final renditions = <Map<String, Object>>[];
    final errors = <Map<String, Object>>[];
    for (final (key, data) in _tree('RENDITIONS')) {
      final tokens = [
        for (var i = 0; i < attributes.length; i++)
          _u16(key as Uint8List, i * 2),
      ];
      final attrs = Map<int, int>.fromIterables(attributes, tokens);
      final identifier = attrs[17];
      final entry = <String, Object>{
        'asset': facets[identifier] ?? '$identifier',
        'attributes': _jsonKeys(attrs),
        'csiSha256': sha256.convert(data).toString(),
      };
      final descriptor = descriptors[identifier];
      if (descriptor != null) {
        final count = _u32(descriptor, 12);
        if (count != attributes.length || descriptor.length != 16 + 4 * count) {
          throw const FormatException('BITMAPKEYS/KEYFORMAT length mismatch');
        }
        final masks = [
          for (var i = 0; i < count; i++) _u32(descriptor, 16 + 4 * i),
        ];
        entry['masks'] = _jsonKeys(Map.fromIterables(attributes, masks));
        for (var i = 0; i < count; i++) {
          final mask = masks[i];
          final value = tokens[i];
          if (mask != 0xffffffff && (value >= 32 || mask & (1 << value) == 0)) {
            errors.add({
              'asset': entry['asset']!,
              'attribute': attributes[i],
              'value': value,
              'mask': '0x${mask.toRadixString(16)}',
            });
          }
        }
      }
      if (ascii.decode(_slice(data, 0, 4), allowInvalid: true) == 'ISTC') {
        final offset = 184 + _u32(data, 168);
        final body = _slice(data, offset, data.length - offset);
        entry.addAll({
          'width': _u32(data, 12),
          'height': _u32(data, 16),
          'scaleFactor': _u32(data, 20),
          'pixelFormat': ascii.decode(_slice(data, 24, 4), allowInvalid: true),
          'colorSpace': _u32(data, 28),
          'sourceName': _string(_slice(data, 40, 128)),
          'bodyOffset': offset,
          'bodySha256': sha256.convert(body).toString(),
        });
        if (body.length >= 16 &&
            ascii.decode(body.sublist(0, 4), allowInvalid: true) == 'MLEC') {
          entry.addAll({
            'bitmapFlags': _u32(body, 4),
            'compression': _u32(body, 8),
            'chunks': _u32(body, 12),
          });
        }
      }
      renditions.add(entry);
    }
    final header = _variable('CARHEADER');
    final metadata = _variables.containsKey('EXTENDED_METADATA')
        ? _variable('EXTENDED_METADATA')
        : Uint8List(1024);
    return {
      'sha256': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
      'coreuiVersion': _u32(header, 4),
      'storageVersion': _u32(header, 8),
      'keyFormat': attributes,
      'deploymentTarget': _string(_slice(metadata, 260, 252)),
      'platform': _string(_slice(metadata, 516, 252)),
      'authoringTool': _string(_slice(metadata, 772, 252)),
      'compilerVersion': _string(_slice(header, 148, 256)),
      'renditions': renditions,
      'lookupMaskErrors': errors,
    };
  }
}

Map<String, int> _jsonKeys(Map<int, int> values) => {
  for (final entry in values.entries) '${entry.key}': entry.value,
};

Uint8List _slice(Uint8List data, int offset, int length) {
  if (offset < 0 || length < 0 || offset + length > data.length) {
    throw const FormatException('Truncated BOM/CAR data');
  }
  return Uint8List.sublistView(data, offset, offset + length);
}

int _u32(Uint8List data, int offset, [Endian endian = Endian.little]) =>
    ByteData.sublistView(_slice(data, offset, 4)).getUint32(0, endian);
int _u16(Uint8List data, int offset, [Endian endian = Endian.little]) =>
    ByteData.sublistView(_slice(data, offset, 2)).getUint16(0, endian);
String _string(Uint8List data) => utf8.decode(
  data.takeWhile((byte) => byte != 0).toList(),
  allowMalformed: true,
);
