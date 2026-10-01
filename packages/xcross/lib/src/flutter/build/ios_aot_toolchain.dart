import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_engine_cache.dart';
import 'package:xcross/src/flutter/errors.dart';

/// The compiler and Flutter adapter are a single, revision-bound contract.
/// The native host compiler is bundled separately from Apple's engine artifacts.
final class IosAotToolchain {
  IosAotToolchain._(this.executable, this.manifest);

  static const flutterRevision = '6a19cca56475dbfba1478ee68d7bd0c2ef891da1';
  static const engineRevision = 'af7e796e161ae0bb1ff0758c71a7105418bd9ded';
  static const dartRevision = 'b530c21f7de367b94fb04787bfed9d8e989d75e8';
  static const snapshotHash = '0451907c2eaa8467e848c0067bfe8ed4';

  final String executable;
  final Map<String, dynamic> manifest;

  static const manifestName = 'xcross-ios-aot-manifest.json';

  static Future<IosAotToolchain> resolve(
    String flutterRoot, {
    String? manifestPath,
  }) async {
    final compiler = await loadCompiler(manifestPath: manifestPath);
    final revision = await ProcessRunner.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: flutterRoot);
    if (revision.exitCode != 0 ||
        revision.stdout.trim() != flutterRevision ||
        IosEngineCache(flutterRoot: flutterRoot).engineHash != engineRevision ||
        File(
              p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'revision'),
            ).readAsStringSync().trim() !=
            dartRevision) {
      throw FlutterBuildError(
        'Release requires Flutter $flutterRevision, engine $engineRevision '
        'and Dart $dartRevision. The selected SDK does not match.',
      );
    }
    return compiler;
  }

  /// Resolve installed payloads independently of SDK validation. Explicit
  /// overrides fail closed rather than silently selecting a different compiler.
  static Future<IosAotToolchain> loadCompiler({
    String? manifestPath,
    String? launcherPath,
    Map<String, String>? environment,
    Abi? hostAbi,
  }) async {
    final host = switch (hostAbi ?? Abi.current()) {
      Abi.windowsX64 => 'windows-x64',
      Abi.linuxX64 => 'linux-x64',
      Abi.linuxArm64 => 'linux-arm64',
      _ => throw FlutterBuildError(
        'iOS AOT requires Windows x64 or Linux x64/ARM64.',
      ),
    };
    final selected =
        manifestPath ??
        (environment ?? Platform.environment)['XCROSS_IOS_AOT_MANIFEST'] ??
        p.join(
          p.dirname(p.dirname(launcherPath ?? Platform.resolvedExecutable)),
          'lib',
          manifestName,
        );
    if (!File(selected).existsSync()) {
      throw FlutterBuildError(
        'The iOS AOT compiler manifest is missing: $selected. '
        'Install a complete xcross bundle built with tool/build_xcross.dart. '
        'Source developers may override it with XCROSS_IOS_AOT_MANIFEST.',
      );
    }
    final manifest =
        jsonDecode(await File(selected).readAsString()) as Map<String, dynamic>;
    final pins = manifest['pins'] as Map<String, dynamic>;
    if (pins['flutterRevision'] != flutterRevision ||
        pins['engineArtifactKey'] != engineRevision ||
        pins['dartRevision'] != dartRevision ||
        pins['snapshotHash'] != snapshotHash) {
      throw FlutterBuildError(
        'iOS AOT compiler manifest does not match the supported Flutter/Dart revision.',
      );
    }
    final cache = p.dirname(p.absolute(selected));
    final relative = manifest['binaryRelativePath'] as String?;
    final executable = p.normalize(
      p.join(
        cache,
        relative ??
            'sdk-$dartRevision/out/ios_aot_product/gen_snapshot_product_ios_arm64.exe',
      ),
    );
    if (!p.isWithin(cache, executable) ||
        !p.isWithin(
          await Directory(cache).resolveSymbolicLinks(),
          await File(executable).resolveSymbolicLinks(),
        )) {
      throw FlutterBuildError(
        'Snapshotter executable escapes its owned cache.',
      );
    }
    final bytes = await File(executable).readAsBytes();
    final data = ByteData.sublistView(bytes);
    var valid = false;
    if (bytes.length >= 64 &&
        host == 'windows-x64' &&
        data.getUint16(0, Endian.little) == 0x5a4d) {
      final pe = data.getUint32(60, Endian.little);
      if (pe + 24 <= bytes.length) {
        final flags = data.getUint16(pe + 22, Endian.little);
        valid =
            data.getUint32(pe, Endian.little) == 0x4550 &&
            data.getUint16(pe + 4, Endian.little) == 0x8664 &&
            flags & 2 != 0 &&
            flags & 0x2000 == 0;
      }
    } else if (bytes.length >= 64 && host.startsWith('linux-')) {
      final kind = data.getUint16(16, Endian.little);
      valid =
          data.getUint32(0) == 0x7f454c46 &&
          bytes[4] == 2 &&
          bytes[5] == 1 &&
          bytes[6] == 1 &&
          (kind == 2 || kind == 3) &&
          data.getUint64(24, Endian.little) != 0 &&
          data.getUint16(18, Endian.little) == (host == 'linux-x64' ? 62 : 183);
    }
    if (!valid ||
        (manifest['host'] as Map?)?['host'] != host ||
        sha256.convert(bytes).toString() != manifest['binarySha256']) {
      throw FlutterBuildError(
        'iOS AOT snapshotter host architecture or SHA-256 does not match its build manifest.',
      );
    }
    return IosAotToolchain._(executable, manifest);
  }
}
