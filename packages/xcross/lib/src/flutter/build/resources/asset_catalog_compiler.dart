import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/atomic_cache.dart';
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/resources/assetkit_patch.dart';
import 'package:xcross/src/flutter/build/resources/assetkit_source.dart';
import 'package:xcross/src/flutter/build/resources/svg_rasterizer.dart';
import 'package:xcross/src/flutter/errors.dart';

const _assetKitChanges =
    'derive availability masks from rendition keys; share bitmap row stride; '
    'pad rows before compression; preserve bitmap transparency; '
    'add synthetic regression tests';

/// Runs the pinned open-source catalog compiler in an xcross-owned host cache.
final class AssetCatalogCompiler {
  AssetCatalogCompiler({String? cacheRoot})
    : cacheRoot =
          cacheRoot ??
          p.join(
            Platform.environment[Platform.isWindows
                    ? 'LOCALAPPDATA'
                    : 'XDG_CACHE_HOME'] ??
                p.join(
                  Platform.environment['HOME'] ?? Directory.systemTemp.path,
                  '.cache',
                ),
            'xcross',
            'resource-tools',
          );
  final String cacheRoot;

  /// Prepare the pinned host compiler during setup; builds reuse this cache.
  Future<void> prepare() async {
    await _tool();
    await SvgRasterizer(cacheRoot).prepare();
  }

  Future<void> compile(
    List<String> catalogs,
    String outputPath, {
    String deploymentTarget = '16.0',
  }) async {
    final output = p.normalize(p.absolute(outputPath));
    for (final catalog in catalogs) {
      validate(catalog);
    }
    final temporary = await Directory(
      p.dirname(output),
    ).createTemp('.asset-input-');
    try {
      final merged = Directory(p.join(temporary.path, 'Merged.xcassets'))
        ..createSync();
      final names = <String>{};
      final identifiers = <int, String>{};
      for (final catalog in catalogs) {
        for (final entity in Directory(
          catalog,
        ).listSync(recursive: true, followLinks: false)) {
          if (entity is! Directory ||
              !{
                '.imageset',
                '.colorset',
                '.appiconset',
              }.contains(p.extension(entity.path))) {
            continue;
          }
          final name = p.basenameWithoutExtension(entity.path);
          if (!names.add(name)) {
            throw FlutterBuildError(
              'Duplicate asset name "$name" across catalogs.',
            );
          }
          // AssetKit currently uses a truncated CRC as the lookup identifier.
          // Distinct names must never silently resolve to another image.
          final identifier = getCrc32(utf8.encode(name)) & 0xffff;
          final collision = identifiers[identifier];
          if (collision != null) {
            throw FlutterBuildError(
              'AssetKit identifier collision between "$collision" and "$name". '
              'Rename one asset to preserve distinct image lookups.',
            );
          }
          identifiers[identifier] = name;
          final destination = p.join(merged.path, p.basename(entity.path));
          if (Directory(destination).existsSync()) {
            throw FlutterBuildError(
              'Asset catalog names collide on this filesystem: ${entity.path}',
            );
          }
          await copyDirectoryPreservingSymlinks(entity.path, destination);
        }
      }
      final request = File(p.join(temporary.path, 'request.json'));
      final hasSvg = merged
          .listSync(recursive: true)
          .whereType<File>()
          .any((file) => p.extension(file.path).toLowerCase() == '.svg');
      await request.writeAsString(
        jsonEncode({
          'catalog': merged.path,
          'output': p.absolute(output),
          'deploymentTarget': deploymentTarget,
          if (hasSvg) 'svgRasterizer': await SvgRasterizer(cacheRoot).prepare(),
        }),
      );
      final executable = await _tool();
      await _run(executable, [request.path], temporary.path);
      final car = File(p.join(output, 'Assets.car'));
      if (!car.existsSync() || car.lengthSync() < 32) {
        throw FlutterBuildError('AssetKit produced no catalog at ${car.path}.');
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  /// Reject semantics that AssetKit otherwise ignores while loading JSON.
  void validate(String catalog) {
    if (!Directory(catalog).existsSync()) {
      throw FlutterBuildError('Missing asset catalog: $catalog');
    }
    for (final entity in Directory(
      catalog,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw FlutterBuildError(
          'Asset catalog symlinks are unsupported: ${entity.path}',
        );
      }
      if (entity is! Directory) continue;
      final extension = p.extension(entity.path);
      if (extension.isNotEmpty &&
          !{'.imageset', '.appiconset', '.colorset'}.contains(extension)) {
        throw FlutterBuildError(
          'Unsupported asset catalog type: ${entity.path}',
        );
      }
    }
    for (final entity in Directory(
      catalog,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File || p.basename(entity.path) != 'Contents.json') {
        continue;
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(entity.readAsStringSync());
      } on Object catch (error) {
        throw FlutterBuildError('Invalid asset JSON ${entity.path}: $error');
      }
      if (decoded is! Map<String, dynamic>) {
        throw FlutterBuildError('Expected asset JSON object: ${entity.path}');
      }
      final kind = p.extension(p.dirname(entity.path));
      final allowed = switch (kind) {
        '.colorset' => {'info', 'colors'},
        '.imageset' || '.appiconset' => {'info', 'images'},
        _ => {'info'},
      };
      _keys(decoded, allowed, entity.path);
      final imageVariants = <String>{};
      for (final raw in _list(decoded['images'], entity.path)) {
        if (raw is! Map<String, dynamic>) {
          throw FlutterBuildError('Invalid image entry: ${entity.path}');
        }
        _keys(
          raw,
          kind == '.appiconset'
              ? {'filename', 'idiom', 'scale', 'size'}
              : {'filename', 'idiom', 'scale', 'appearances', 'display-gamut'},
          entity.path,
        );
        _appearances(raw['appearances'], entity.path);
        if (kind != '.appiconset') {
          _uniqueVariant(raw, imageVariants, entity.path, image: true);
        }
        final filename = raw['filename'];
        if (filename != null && filename is! String) {
          throw FlutterBuildError('Invalid asset filename: ${entity.path}');
        }
        if (filename is String && filename.isNotEmpty) {
          final resolved = p.normalize(
            p.join(p.dirname(entity.path), filename),
          );
          if (!p.isWithin(p.dirname(entity.path), resolved) ||
              p.isAbsolute(filename)) {
            throw FlutterBuildError(
              'Asset filename escapes its imageset: ${entity.path}',
            );
          }
          if (!{
            '.png',
            '.jpg',
            '.jpeg',
            '.svg',
          }.contains(p.extension(filename).toLowerCase())) {
            throw FlutterBuildError('Unsupported image format: $resolved');
          }
        }
      }
      final colorVariants = <String>{};
      for (final raw in _list(decoded['colors'], entity.path)) {
        if (raw is! Map<String, dynamic>) {
          throw FlutterBuildError('Invalid color entry: ${entity.path}');
        }
        _keys(raw, {
          'idiom',
          'color',
          'appearances',
          'display-gamut',
        }, entity.path);
        _appearances(raw['appearances'], entity.path);
        _uniqueVariant(raw, colorVariants, entity.path);
        final color = raw['color'];
        if (color is! Map<String, dynamic>) {
          throw FlutterBuildError('Invalid color object: ${entity.path}');
        }
        _keys(color, {'color-space', 'components'}, entity.path);
        if (!{'srgb', 'display-p3'}.contains(color['color-space'])) {
          throw FlutterBuildError('Unsupported color space: ${entity.path}');
        }
        final components = color['components'];
        if (components is! Map<String, dynamic>) {
          throw FlutterBuildError('Invalid color components: ${entity.path}');
        }
        _keys(components, {'red', 'green', 'blue', 'alpha'}, entity.path);
      }
    }
  }

  void _uniqueVariant(
    Map<String, dynamic> entry,
    Set<String> variants,
    String path, {
    bool image = false,
  }) {
    final filename = entry['filename'];
    if (image && (filename == null || filename == '')) return;
    final scales =
        filename is String && p.extension(filename).toLowerCase() == '.svg'
        ? ['1x', '2x', '3x']
        : [entry['scale'] ?? '1x'];
    for (final scale in scales) {
      final key = jsonEncode([
        entry['idiom'] ?? 'universal',
        scale,
        _list(entry['appearances'], path).isNotEmpty,
      ]);
      if (!variants.add(key)) {
        throw FlutterBuildError(
          'Ambiguous asset variants in $path: overlapping idiom, scale and appearance. '
          'SVGs occupy all three bitmap scales; display-gamut selection is unsupported.',
        );
      }
    }
  }

  List<dynamic> _list(Object? value, String path) {
    if (value == null) return const [];
    if (value is List) return value;
    throw FlutterBuildError('Expected asset array: $path');
  }

  void _appearances(Object? value, String path) {
    final appearances = _list(value, path);
    if (appearances.length > 1) {
      throw FlutterBuildError(
        'Multiple asset appearance conditions are unsupported: $path',
      );
    }
    for (final appearance in appearances) {
      if (appearance is! Map<String, dynamic>) {
        throw FlutterBuildError('Invalid asset appearance: $path');
      }
      _keys(appearance, {'appearance', 'value'}, path);
      if (appearance['appearance'] != 'luminosity' ||
          appearance['value'] != 'dark') {
        throw FlutterBuildError('Unsupported asset appearance: $path');
      }
    }
  }

  void _keys(Map<String, dynamic> object, Set<String> allowed, String path) {
    for (final key in object.keys) {
      if (!allowed.contains(key)) {
        throw FlutterBuildError(
          'Unsupported asset property "$key" in $path; it would otherwise be ignored.',
        );
      }
    }
  }

  Future<String> _tool() async {
    final version = await _run('swift', ['--version'], Directory.current.path);
    final match = RegExp(r'Swift version (\d+)\.(\d+)').firstMatch(version);
    if (match == null ||
        int.parse(match.group(1)!) < 6 ||
        (int.parse(match.group(1)!) == 6 && int.parse(match.group(2)!) < 3)) {
      throw FlutterBuildError(
        'The asset catalog compiler requires native Swift 6.3 or newer. '
        'Selected toolchain: ${version.trim()}',
      );
    }
    final key = sha256
        .convert(
          utf8.encode(
            '$assetKitRevision\n$assetKitCompatibilityPatch\n'
            '$assetKitPackage\n$assetKitMain\n$_assetKitChanges\n$version',
          ),
        )
        .toString();
    final destination = p.join(cacheRoot, key);
    final name = Platform.isWindows ? 'xcross-assets.exe' : 'xcross-assets';
    await ensureAtomicCache(
      destination: destination,
      isComplete: (root) =>
          File(p.join(root, name)).existsSync() &&
          File(p.join(root, 'complete')).existsSync(),
      populate: (stage) async {
        final package = p.join(stage, 'source');
        final source = Directory(
          p.join(package, 'Sources', 'XcrossAssetCompiler'),
        );
        await source.create(recursive: true);
        await File(
          p.join(package, 'Package.swift'),
        ).writeAsString(assetKitPackage);
        await File(
          p.join(source.path, 'Main.swift'),
        ).writeAsString(assetKitMain);
        final dependency = p.join(package, 'Dependencies', 'AssetKit');
        await Directory(p.dirname(dependency)).create(recursive: true);
        await _run('git', [
          '-c',
          'core.autocrlf=false',
          'clone',
          '--no-checkout',
          'https://github.com/xtool-org/AssetKit',
          dependency,
        ], package);
        await _run('git', [
          '-c',
          'core.autocrlf=false',
          'checkout',
          '--detach',
          assetKitRevision,
        ], dependency);
        final patchBytes = utf8.encode(assetKitCompatibilityPatch);
        if (sha256.convert(patchBytes).toString() != assetKitPatchSha256) {
          throw FlutterBuildError(
            'AssetKit compatibility patch checksum mismatch.',
          );
        }
        final patch = File(p.join(package, 'assetkit-compatibility.patch'));
        await patch.writeAsBytes(patchBytes);
        await _run('git', ['apply', '--check', patch.path], dependency);
        await _run('git', ['apply', patch.path], dependency);
        await Log.logStep(
          'Building AssetKit compiler',
          () => _run('swift', [
            'build',
            '--package-path',
            package,
            '-c',
            'release',
          ], package),
        );
        final binaryPath = (await _run('swift', [
          'build',
          '--package-path',
          package,
          '-c',
          'release',
          '--show-bin-path',
        ], package)).trim();
        for (final file in Directory(binaryPath).listSync()) {
          if (file is File &&
              (p.basename(file.path) == name ||
                  p.extension(file.path).toLowerCase() == '.dll')) {
            await file.copy(p.join(stage, p.basename(file.path)));
          }
        }
        // Keep the resolved sources, patch and full third-party notices with
        // the binary. No SDK, global Swift cache or application sources change.
        final licenses = Directory(p.join(stage, 'licenses'));
        await licenses.create();
        // The embedded patch also appears inside an AOT-compiled CLI; retain
        // its MIT notice there, not only in a source-package sidecar.
        await File(
          p.join(licenses.path, 'AssetKit-MIT.txt'),
        ).writeAsString(assetKitLicense);
        final licenseSources = {
          'LZFSE-BSD.txt': p.join(dependency, 'Sources', 'CLZFSE', 'LICENSE'),
          'LZFSE-provenance.txt': p.join(
            dependency,
            'Sources',
            'CLZFSE',
            'UPSTREAM.md',
          ),
          for (final name in ['swift-png', 'h']) ...{
            '$name-LICENSE.txt': p.join(
              package,
              '.build',
              'checkouts',
              name,
              'LICENSE',
            ),
            '$name-NOTICE.txt': p.join(
              package,
              '.build',
              'checkouts',
              name,
              'NOTICE',
            ),
          },
        };
        for (final entry in licenseSources.entries) {
          await File(entry.value).copy(p.join(licenses.path, entry.key));
        }
        await File(p.join(licenses.path, 'MODIFICATIONS.txt')).writeAsString(
          'AssetKit $assetKitRevision with xcross compatibility fixes.\n'
          'Patch SHA-256: $assetKitPatchSha256\n'
          'Changes: $_assetKitChanges.\n'
          'The source and exact patch are retained in the adjacent source directory.\n',
        );
        await File(
          p.join(stage, 'complete'),
        ).writeAsString('$assetKitRevision\n$assetKitPatchSha256\n');
      },
    );
    return p.join(destination, name);
  }

  Future<String> _run(
    String command,
    List<String> arguments,
    String directory,
  ) async {
    try {
      final result = await ProcessRunner.run(
        command,
        arguments,
        workingDirectory: directory,
      );
      if (result.exitCode != 0) {
        throw FlutterBuildError(
          'Resource compiler failed ($command):\n${result.stdout}\n${result.stderr}',
        );
      }
      return result.stdout;
    } on ProcessException catch (error) {
      throw FlutterBuildError(
        'Resource compiler needs native Swift 6.3+ and Git on PATH: $error',
      );
    }
  }
}
