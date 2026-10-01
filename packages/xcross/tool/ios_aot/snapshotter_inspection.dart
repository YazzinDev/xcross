import 'dart:convert';
import 'dart:typed_data';

import 'package:xcross/src/flutter/build/internal/ios_aot_artifact.dart';

// Assertions retain condition/message order at call sites.
// ignore: avoid_positional_boolean_parameters
void requireSnapshotter(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, String> inspectSnapshotterHost(Uint8List bytes, String host) {
  requireSnapshotter(bytes.length >= 64, 'Truncated snapshotter executable');
  final data = ByteData.sublistView(bytes);
  if (host == 'windows-x64') {
    requireSnapshotter(
      data.getUint16(0, Endian.little) == 0x5a4d,
      'Not a Windows PE executable',
    );
    final pe = data.getUint32(60, Endian.little);
    requireSnapshotter(
      pe + 26 <= bytes.length && data.getUint32(pe, Endian.little) == 0x4550,
      'Invalid PE header',
    );
    final flags = data.getUint16(pe + 22, Endian.little);
    requireSnapshotter(
      data.getUint16(pe + 4, Endian.little) == 0x8664,
      'Snapshotter host is not Windows x64',
    );
    requireSnapshotter(
      flags & 2 != 0 && flags & 0x2000 == 0,
      'Snapshotter must be an executable, not a DLL',
    );
    return {'format': 'PE', 'host': host};
  }
  requireSnapshotter(
    host == 'linux-x64' || host == 'linux-arm64',
    'Unsupported snapshotter host',
  );
  requireSnapshotter(
    data.getUint32(0) == 0x7f454c46 &&
        bytes[4] == 2 &&
        bytes[5] == 1 &&
        bytes[6] == 1,
    'Not a little-endian ELF64 executable',
  );
  final kind = data.getUint16(16, Endian.little);
  requireSnapshotter(
    (kind == 2 || kind == 3) && data.getUint64(24, Endian.little) != 0,
    'ELF must be an executable',
  );
  requireSnapshotter(
    data.getUint16(18, Endian.little) == (host == 'linux-x64' ? 62 : 183),
    'Snapshotter ELF host architecture mismatch',
  );
  return {'format': 'ELF', 'host': host};
}

/// Audit all VM and runtime compilation units, not just the top-level target.
Map<String, Object> auditSnapshotterCommands(
  List<dynamic> entries,
  String host,
) {
  const required = {
    'DART_TARGET_OS_MACOS',
    'DART_TARGET_OS_MACOS_IOS',
    'TARGET_ARCH_ARM64',
    'PRODUCT',
  };
  const forbidden = {
    'DART_TARGET_OS_WINDOWS',
    'DART_TARGET_OS_LINUX',
    'DART_TARGET_OS_ANDROID',
    'DART_COMPRESSED_POINTERS',
    'TARGET_ARCH_X64',
    'DEBUG',
    'DART_DYNAMIC_MODULES',
  };
  final audited = <String>[];
  for (final value in entries) {
    final entry = value as Map<String, dynamic>;
    final source = (entry['file'] as String).replaceAll(r'\', '/');
    if (!source.contains('/runtime/')) continue;
    final command = entry['command'] as String;
    final defines = command
        .split(RegExp(r'\s+'))
        .where((word) => word.startsWith('-D'))
        .map((word) => word.substring(2))
        .toSet();
    requireSnapshotter(
      defines.containsAll(required),
      'Incomplete iOS target configuration: $source',
    );
    requireSnapshotter(
      defines.intersection(forbidden).isEmpty,
      'Conflicting target configuration: $source',
    );
    final triple = switch (host) {
      'windows-x64' => 'x86_64-pc-windows-msvc',
      'linux-x64' => 'x86_64-linux-gnu',
      'linux-arm64' => 'aarch64-linux-gnu',
      _ => throw UnsupportedError('Unsupported compiler host $host'),
    };
    requireSnapshotter(
      command.contains('--target=$triple'),
      'C++ compiler target is not $host',
    );
    if (!source.contains('/runtime/bin/') || source.contains('gen_snapshot')) {
      requireSnapshotter(
        defines.contains('DART_PRECOMPILER'),
        'Missing precompiler configuration: $source',
      );
    }
    audited.add(source);
  }
  for (final suffix in [
    'gen_snapshot.cc',
    'mach_o.cc',
    'precompiler.cc',
    if (host == 'windows-x64') 'os_win.cc' else 'os_linux.cc',
    'builtin.cc',
  ]) {
    requireSnapshotter(
      audited.any((source) => source.endsWith('/$suffix')),
      'Missing compiler dependency family: $suffix',
    );
  }
  return {
    'runtimeCompilationUnits': audited.length,
    'requiredDefines': required.toList()..sort(),
    'forbiddenDefines': forbidden.toList()..sort(),
  };
}

/// Reuse the production snapshot/loader check, retaining the probe's additional
/// rpath, section-boundary and signature-container checks.
Map<String, Object> inspectSnapshotterProduct(
  Uint8List bytes,
  String snapshotHash,
) {
  final result = inspectIosAotArtifact(
    bytes,
    snapshotHash: snapshotHash,
    minimumOS: '13.0',
  );
  final data = ByteData.sublistView(bytes);
  final rpaths = <String>{};
  var offset = 32;
  for (var i = 0; i < data.getUint32(16, Endian.little); i++) {
    final command = data.getUint32(offset, Endian.little);
    final size = data.getUint32(offset + 4, Endian.little);
    if (command == 0x19) {
      requireSnapshotter(
        72 + data.getUint32(offset + 64, Endian.little) * 80 <= size,
        'Sections exceed segment command',
      );
    } else if (command == 0x8000001c) {
      requireSnapshotter(size >= 12, 'Truncated rpath');
      final start = offset + data.getUint32(offset + 8, Endian.little);
      final end = offset + size;
      requireSnapshotter(
        start >= offset + 12 && start < end,
        'Invalid rpath offset',
      );
      final zero = bytes.indexOf(0, start);
      requireSnapshotter(zero >= start && zero < end, 'Unterminated rpath');
      rpaths.add(utf8.decode(bytes.sublist(start, zero)));
    } else if (command == 0x1d) {
      requireSnapshotter(size == 16, 'Invalid code signature command');
      requireSnapshotter(
        data.getUint32(offset + 8, Endian.little) +
                data.getUint32(offset + 12, Endian.little) <=
            bytes.length,
        'Signature extends beyond file',
      );
    }
    offset += size;
  }
  requireSnapshotter(
    rpaths.length == 2 &&
        rpaths.containsAll({
          '@executable_path/Frameworks',
          '@loader_path/Frameworks',
        }),
    'Wrong rpaths',
  );
  return {...result, 'rpaths': rpaths.toList()};
}
