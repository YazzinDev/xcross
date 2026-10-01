import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// An object in UIKit's NIBArchive object graph. Repeated keys encode arrays.
final class NibObject {
  NibObject(this.className, [Map<String, Object> fields = const {}])
    : fields = fields.entries.map((e) => (e.key, e.value)).toList();
  final String className;
  final List<(String, Object)> fields;
  void set(String key, Object value) {
    fields.removeWhere((entry) => entry.$1 == key);
    fields.add((key, value));
  }
}

/// NIB type 8 payload (as opposed to an NSString object reference).
final class NibBytes {
  NibBytes(this.value);
  NibBytes.text(String value) : value = Uint8List.fromList(utf8.encode(value));
  NibBytes.geometry(List<double> coordinates) : value = _geometry(coordinates);
  final Uint8List value;
  static Uint8List _geometry(List<double> values) {
    final data = ByteData(1 + values.length * 8)..setUint8(0, 7);
    for (var i = 0; i < values.length; i++) {
      data.setFloat64(1 + i * 8, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

/// Writes the documented NIBArchive tables; object references preserve cycles.
Uint8List encodeNib(NibObject root) {
  final objects = <NibObject>[];
  final indices = HashMap<NibObject, int>.identity();
  final fields = <List<(String, Object)>>[];
  Object normalize(Object value) {
    if (value is String) {
      return NibObject('NSString', {'NS.bytes': NibBytes.text(value)});
    }
    if (value is List) {
      final array = NibObject('NSArray', {'NSInlinedValue': true});
      for (final item in value) {
        array.fields.add(('UINibEncoderEmptyKey', item as Object));
      }
      return array;
    }
    return value;
  }

  void visit(NibObject object) {
    if (indices.containsKey(object)) return;
    indices[object] = objects.length;
    objects.add(object);
    final normalized = object.fields
        .map((entry) => (entry.$1, normalize(entry.$2)))
        .toList();
    fields.add(normalized);
    for (final entry in normalized) {
      if (entry.$2 case final NibObject child) visit(child);
    }
  }

  visit(root);
  final classes = <String>[];
  final keys = <String>[];
  int intern(List<String> table, String value) {
    final index = table.indexOf(value);
    if (index >= 0) return index;
    table.add(value);
    return table.length - 1;
  }

  final objectTable = _NibBuffer();
  final values = _NibBuffer();
  var valueCount = 0;
  for (var i = 0; i < objects.length; i++) {
    objectTable
      ..variable(intern(classes, objects[i].className))
      ..variable(valueCount)
      ..variable(fields[i].length);
    for (final (key, value) in fields[i]) {
      values.variable(intern(keys, key));
      switch (value) {
        case NibObject():
          values
            ..byte(10)
            ..u32(indices[value]!);
        case NibBytes():
          values
            ..byte(8)
            ..variable(value.value.length)
            ..add(value.value);
        case bool():
          values.byte(value ? 5 : 4);
        case int():
          if (value >= 0 && value < 256) {
            values
              ..byte(0)
              ..byte(value);
          } else if (value >= 0 && value < 65536) {
            values
              ..byte(1)
              ..u16(value);
          } else {
            values
              ..byte(2)
              ..u32(value);
          }
        case double():
          values
            ..byte(7)
            ..f64(value);
        default:
          throw ArgumentError('Unsupported NIB value: ${value.runtimeType}');
      }
      valueCount++;
    }
  }
  final keyTable = _NibBuffer();
  for (final key in keys) {
    final bytes = utf8.encode(key);
    keyTable
      ..variable(bytes.length)
      ..add(bytes);
  }
  final classTable = _NibBuffer();
  for (final name in classes) {
    final bytes = utf8.encode(name);
    classTable
      ..variable(bytes.length + 1)
      ..variable(0)
      ..add(bytes)
      ..byte(0);
  }
  final output = _NibBuffer()
    ..add(ascii.encode('NIBArchive'))
    ..u32(1)
    ..u32(9);
  var offset = 50;
  final tables = [objectTable, keyTable, values, classTable];
  final counts = [objects.length, keys.length, valueCount, classes.length];
  for (var i = 0; i < tables.length; i++) {
    output
      ..u32(counts[i])
      ..u32(offset);
    offset += tables[i].length;
  }
  for (final table in tables) {
    output.add(table.bytes.takeBytes());
  }
  return output.bytes.takeBytes();
}

final class _NibBuffer {
  final bytes = BytesBuilder(copy: false);
  int get length => bytes.length;
  void add(List<int> value) => bytes.add(value);
  void byte(int value) => bytes.addByte(value);
  void u16(int value) => add(
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u32(int value) => add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void f64(double value) => add(
    (ByteData(8)..setFloat64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void variable(int value) {
    var remaining = value;
    do {
      final low = remaining & 127;
      remaining >>= 7;
      byte(remaining == 0 ? low | 128 : low);
    } while (remaining != 0);
  }
}
