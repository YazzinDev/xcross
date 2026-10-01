import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/package_config_resolver.dart';

/// Whether any package in the resolved package graph has a build hook.
Future<bool> hasNativeAssetsBuildHooks(
  String projectRoot, {
  bool includeLinkHooks = false,
}) async {
  final String configPath;
  try {
    configPath = await PackageConfigResolver.require(projectRoot);
  } on FormatException catch (error) {
    throw FlutterBuildError(
      'Could not read package config from $projectRoot: malformed JSON '
      '($error). Run `flutter pub get` and retry.',
    );
  }
  final packageConfig = File(configPath);

  final Object? json;
  try {
    json = jsonDecode(packageConfig.readAsStringSync());
  } on FormatException catch (error) {
    throw FlutterBuildError(
      'Could not read ${packageConfig.path}: malformed JSON '
      '(${error.message}). Run `flutter pub get` and retry.',
    );
  } on FileSystemException catch (error) {
    throw FlutterBuildError(
      'Could not read ${packageConfig.path}: ${error.message}',
    );
  }

  if (json is! Map<String, Object?> || json['packages'] is! List<Object?>) {
    throw FlutterBuildError(
      'Could not read ${packageConfig.path}: expected a package_config with a '
      '`packages` list. Run `flutter pub get` and retry.',
    );
  }

  final configUri = packageConfig.uri;
  for (final package in json['packages']! as List<Object?>) {
    if (package is! Map<String, Object?> || package['rootUri'] is! String) {
      continue;
    }
    try {
      final root = configUri.resolve(package['rootUri']! as String);
      if (!root.isScheme('file')) continue;
      final rootDirectory = Uri.directory(root.toFilePath());
      if (File.fromUri(rootDirectory.resolve('hook/build.dart')).existsSync() ||
          (includeLinkHooks &&
              File.fromUri(
                rootDirectory.resolve('hook/link.dart'),
              ).existsSync())) {
        return true;
      }
    } on FormatException {
      // A malformed package entry cannot contain a discoverable local hook.
      continue;
    }
  }
  return false;
}
