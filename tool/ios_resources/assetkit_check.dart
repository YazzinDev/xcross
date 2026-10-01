// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:xcross/src/flutter/build/resources/asset_catalog_compiler.dart';
import 'package:xcross/src/flutter/build/resources/assetkit_patch.dart';

/// Run with the workspace package configuration. The exported patch can be
/// applied to the AssetKit checkout for independent upstream testing.
Future<void> main(List<String> arguments) async {
  if (arguments.length == 2 && arguments.first == 'export-patch') {
    await File(arguments[1]).writeAsString(assetKitCompatibilityPatch);
    return;
  }
  if (arguments.length < 3 || arguments.first != 'compile') {
    stderr.writeln(
      'Usage: assetkit_check.dart compile <catalog> <output> [cache-root]\n'
      '       assetkit_check.dart export-patch <output.patch>',
    );
    exitCode = 64;
    return;
  }
  final output = Directory(arguments[2]).absolute;
  await output.create(recursive: true);
  await AssetCatalogCompiler(
    cacheRoot: arguments.length > 3 ? Directory(arguments[3]).absolute.path : null,
  ).compile([Directory(arguments[1]).absolute.path], output.path);
}
