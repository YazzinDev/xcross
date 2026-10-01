import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/atomic_cache.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Linux/macOS use the renderer installed by setup. Windows uses a verified
/// native upstream binary because librsvg's Unix launcher is unavailable.
final class SvgRasterizer {
  SvgRasterizer(this.cacheRoot);

  final String cacheRoot;
  static const _archiveHash =
      '5684e59ceaa53ce720b49efb441b0918ae99d04e8ce3f6f753664524592d67f1';
  static const _licenseHash =
      'f5d934dc281b44e0003ee461ac740b18b6629a454decd872c774d34e4ee0b21d';

  Future<String> prepare() async {
    if (!Platform.isWindows) {
      final executable = await ProcessRunner.which('rsvg-convert');
      if (executable == null) {
        throw FlutterBuildError(
          'SVG assets require rsvg-convert. Run `xcross setup` to install it.',
        );
      }
      return executable;
    }
    final destination = p.join(cacheRoot, 'resvg-0.47.0-$_archiveHash');
    await ensureAtomicCache(
      destination: destination,
      isComplete: (root) =>
          File(p.join(root, 'resvg.exe')).existsSync() &&
          File(p.join(root, 'LICENSE-MIT')).existsSync(),
      populate: (stage) async {
        final archive = File(p.join(stage, 'resvg-win64.zip'));
        await _download(
          'https://github.com/linebender/resvg/releases/download/v0.47.0/resvg-win64.zip',
          archive,
          _archiveHash,
        );
        final entries = ZipDecoder().decodeBytes(await archive.readAsBytes());
        final executable = entries.files
            .where((file) => file.name == 'resvg.exe')
            .single;
        if (!executable.isFile || executable.isSymbolicLink) {
          throw FlutterBuildError('Invalid resvg executable archive entry.');
        }
        await File(p.join(stage, 'resvg.exe')).writeAsBytes(executable.content);
        await _download(
          'https://raw.githubusercontent.com/linebender/resvg/3a0fdba53ccf2d346b54cc53ba7adf0ee60d0707/LICENSE-MIT',
          File(p.join(stage, 'LICENSE-MIT')),
          _licenseHash,
        );
        await File(p.join(stage, 'SOURCE.txt')).writeAsString(
          'resvg 0.47.0, upstream Windows binary (unmodified)\n'
          'Source: https://github.com/linebender/resvg/tree/3a0fdba53ccf2d346b54cc53ba7adf0ee60d0707\n'
          'Archive SHA-256: $_archiveHash\n',
        );
      },
    );
    return p.join(destination, 'resvg.exe');
  }

  Future<void> _download(String url, File output, String expectedHash) async {
    await Downloader.downloadToFile(url, output);
    final actual = (await sha256.bind(output.openRead()).first).toString();
    if (actual != expectedHash) {
      throw FlutterBuildError('SVG renderer checksum mismatch: $url');
    }
  }
}
