import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/apple/mach_o.dart';
import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/flutter/build/macho_linkedit_aligner.dart';
import 'package:xcross/src/flutter/errors.dart';

const _fatMachOMagics = <int>{
  0xcafebabe, // FAT_MAGIC
  0xbebafeca, // FAT_CIGAM
  0xcafebabf, // FAT_MAGIC_64
  0xbfbafeca, // FAT_CIGAM_64
};

List<String> collectNativeAssetFrameworks(
  String manifest,
  String outputDirectory, {
  String? projectRoot,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(manifest);
  } on FormatException catch (error) {
    throw FlutterBuildError('Invalid native assets manifest: $error');
  }
  if (decoded is! Map<String, dynamic> ||
      decoded['native-assets'] is! Map<String, dynamic>) {
    throw FlutterBuildError(
      'Invalid native assets manifest: missing native-assets',
    );
  }
  final targets = decoded['native-assets'] as Map<String, dynamic>;
  final assets = targets['ios_arm64'];
  if (assets == null) return const [];
  if (assets is! Map<String, dynamic>) {
    throw FlutterBuildError(
      'Invalid native assets manifest: ios_arm64 is not a map',
    );
  }
  final directories = <Directory>[
    Directory(p.join(outputDirectory, 'native_assets')),
    if (projectRoot != null)
      Directory(p.join(projectRoot, 'build', 'native_assets', 'ios')),
  ];
  final frameworks = <String, String>{};
  for (final asset in assets.values) {
    if (asset is! List || asset.length < 2 || asset[1] is! String) continue;
    if (asset[0] != 'absolute' && asset[0] != 'relative') continue;
    final path = (asset[1] as String).replaceAll(r'\', '/');
    final component = path
        .split('/')
        .lastIndexWhere((part) => part.endsWith('.framework'));
    if (component < 0) continue;
    final frameworkPath = path.split('/').take(component + 1).join('/');
    final candidates = p.isAbsolute(frameworkPath)
        ? [frameworkPath]
        : [
            for (final directory in directories)
              p.normalize(p.join(directory.path, frameworkPath)),
          ];
    final found = candidates
        .where((path) => Directory(path).existsSync())
        .toList();
    if (found.isEmpty) {
      throw FlutterBuildError(
        'Native asset framework not found: $frameworkPath',
      );
    }
    // The active assemble output precedes the package-local fallback. A
    // previous build may leave the same framework in both locations; choose
    // one source now and carry that exact path through repair and embedding.
    final selected = found.first;
    final name = p.basename(selected);
    final previous = frameworks[name];
    if (previous != null && !p.equals(previous, selected)) {
      throw FlutterBuildError('Native asset framework name collision: $name');
    }
    frameworks[name] = selected;
  }
  return frameworks.values.toList();
}

/// Keep a native asset eager-loaded only when a SwiftPM plugin dylib imports
/// one of its symbols. Other native assets remain embedded for Flutter's
/// manifest-driven `dlopen` path instead of affecting Runner startup.
Future<List<String>> nativeFrameworksRequiredByPlugins(
  Iterable<String> frameworks,
  Iterable<String> pluginLibraries,
) async {
  final imports = <String>{};
  for (final library in pluginLibraries) {
    imports.addAll(await _externalMachOSymbols(library, undefined: true));
  }
  if (imports.isEmpty) return const [];

  final required = <String>[];
  for (final framework in frameworks) {
    final binary = p.join(framework, p.basenameWithoutExtension(framework));
    final exports = await _externalMachOSymbols(binary, undefined: false);
    if (exports.any(imports.contains)) required.add(framework);
  }
  return required;
}

Future<Set<String>> _externalMachOSymbols(
  String path, {
  required bool undefined,
}) async {
  final bytes = await File(path).readAsBytes();
  final file = MachOFile.parse(
    bytes,
    invalid: (message) =>
        throw FlutterBuildError('Invalid Mach-O $path: $message'),
  );
  final symbols = <String>{};
  for (final command in file.commands) {
    if (command.type != MachOConstants.lcSymtab) continue;
    final table = file.parseSymbolTable(command);
    for (var index = 0; index < table.symbolCount; index++) {
      final symbol = table.symbolAt(index);
      if (symbol.type & 0xe0 != 0 || symbol.type & 0x01 == 0) continue;
      final kind = symbol.type & 0x0e;
      if (undefined ? kind != 0 : kind != 0x0e && kind != 0x02) continue;
      symbols.add(table.symbolName(index, symbol));
    }
  }
  return symbols;
}

Future<bool> isFatMachO(String path) async {
  final file = File(path);
  if (!file.existsSync() || await file.length() < 4) return false;
  final bytes = await file.openRead(0, 4).expand((chunk) => chunk).toList();
  final magic = ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(0);
  return _fatMachOMagics.contains(magic);
}

/// Repairs native-asset binaries whose LINKEDIT string table `ld64.lld`
/// left 4-byte aligned, which dyld on iOS 26 refuses to load.
///
/// Runs over every framework because any of them can carry the layout that
/// triggers it (an odd indirect-symbol count); binaries that are already
/// aligned are left untouched.
Future<void> alignNativeAssetLinkedit(Iterable<String> frameworks) async {
  for (final framework in frameworks) {
    final binary = p.join(framework, p.basenameWithoutExtension(framework));
    if (await MachOLinkeditAligner.alignFile(binary)) {
      Log.logTrace('realigned LINKEDIT string table in $binary');
    }
  }
}

Future<void> normalizeNativeAssetInstallNames(
  Iterable<String> frameworks,
) async {
  final installNames = <String, String>{};
  final binaries = <String, String>{};
  for (final framework in frameworks) {
    final name = p.basenameWithoutExtension(framework);
    final binary = p.join(framework, name);
    binaries[name] = binary;
    final installName = '@rpath/$name.framework/$name';
    installNames[name] = installName;
    installNames['$name.dylib'] = installName;
    installNames['lib$name.dylib'] = installName;
  }
  for (final entry in binaries.entries) {
    await MachODylibRewriter.rewriteFile(
      entry.value,
      producedDylibNames: const {},
      installName: installNames[entry.key],

      producedInstallNames: installNames,
    );
  }
}

Future<void> thinFrameworksToArm64(
  Iterable<String> frameworks, {
  required String lipo,
}) async {
  for (final framework in frameworks) {
    final binary = p.join(framework, p.basenameWithoutExtension(framework));
    if (!await isFatMachO(binary)) continue;

    final thin = '$binary.xcross-thin';
    try {
      await ProcessRunner.runChecked(lipo, [
        '-thin',
        'arm64',
        binary,
        '-output',
        thin,
      ], label: 'llvm-lipo');
      // File.rename cannot replace an existing file on Windows. copy() can,
      // and keeps the original intact until lipo has completed successfully.
      await File(thin).copy(binary);
    } finally {
      final temporary = File(thin);
      if (temporary.existsSync()) await temporary.delete();
    }
  }
}
