import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/flutter/build/pbxproj.dart';
import 'package:xcross/src/flutter/build/resources/asset_catalog_compiler.dart';
import 'package:xcross/src/flutter/build/resources/storyboard_compiler.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Fail on unsupported source semantics before compiling Dart and plugins.
@internal
Future<void> validateIosResourceSources(
  String projectRoot, {
  bool strict = true,
}) async {
  // Debug retains the existing precompiled-resource/programmatic fallback.
  if (!strict) return;
  final path = PbxProject.findPbxproj(projectRoot);
  if (path == null) return;
  final project = PbxProject.parseFile(path);
  if (project == null) {
    throw FlutterBuildError('Cannot read Xcode resource declarations: $path');
  }
  final target = project.applicationTarget;
  if (target == null) return;
  final resources = <String>{
    ...project.buildPhaseFiles(target, 'PBXResourcesBuildPhase'),
    ...project.synchronizedFiles(target).where(PbxProject.isTargetResource),
  };
  for (final source in resources) {
    final extension = p.extension(source);
    if (extension == '.xcassets') {
      AssetCatalogCompiler().validate(source);
    } else if ({'.storyboard', '.xib'}.contains(extension)) {
      final path = File(source).existsSync()
          ? source
          : _findRelocatedResource(projectRoot, source);
      if (path == null) {
        throw FlutterBuildError('Missing Interface Builder source: $source');
      }
      StoryboardCompiler().compile(
        await File(path).readAsString(),
        source: path,
      );
    }
  }
}

/// Stages the application target's Xcode resources into an app bundle.
@internal
Future<String?> stageIosBundleResources({
  required String projectRoot,
  required String bundleDir,
  bool strict = false,
  bool compileSources = false,
  String deploymentTarget = '16.0',
}) async {
  final pbxprojPath = PbxProject.findPbxproj(projectRoot);
  final project = pbxprojPath == null
      ? null
      : PbxProject.parseFile(pbxprojPath);
  final target = project?.applicationTarget;
  if (project == null || target == null) return null;

  final infoPlist = _resolveBuildSettingPath(
    project,
    project.buildSetting(target, 'INFOPLIST_FILE'),
  );
  final resources = <String>{
    ...project.buildPhaseFiles(target, 'PBXResourcesBuildPhase'),
    ...project.synchronizedFiles(target).where(PbxProject.isTargetResource),
  };
  String? assetPlist;
  if (compileSources) {
    final catalogs = resources
        .where((source) => p.extension(source) == '.xcassets')
        .toList();
    if (catalogs.isNotEmpty) {
      final temporary = await Directory(
        p.dirname(bundleDir),
      ).createTemp('.xcross-assets-');
      try {
        await AssetCatalogCompiler().compile(
          catalogs,
          temporary.path,
          deploymentTarget: deploymentTarget,
        );
        for (final file in temporary.listSync().whereType<File>()) {
          if (p.basename(file.path) == 'asset-info.plist') {
            assetPlist = await file.readAsString();
          } else {
            await file.copy(p.join(bundleDir, p.basename(file.path)));
          }
        }
      } finally {
        await temporary.delete(recursive: true);
      }
    }
  }
  for (var source in resources) {
    if (p.extension(source) == '.xcassets') {
      if (compileSources) continue;
      if (!strict) continue;
      final compiled = p.join(p.dirname(source), 'Assets.car');
      if (!File(compiled).existsSync()) {
        throw FlutterBuildError(
          'Release resource $source requires compiled Assets.car; actool is not available on this host.',
        );
      }
      source = compiled;
    }
    if (p.basename(source) == 'AppFrameworkInfo.plist') continue;
    if (infoPlist != null && p.equals(source, infoPlist)) continue;

    if (compileSources &&
        {'.storyboard', '.xib'}.contains(p.extension(source))) {
      final relocated = File(source).existsSync()
          ? source
          : _findRelocatedResource(projectRoot, source);
      if (relocated == null) {
        throw FlutterBuildError('Missing Interface Builder source: $source');
      }
      final localization = _nearestLocalization(source);
      final directory =
          localization == null || p.basename(localization) == 'Base.lproj'
          ? bundleDir
          : p.join(bundleDir, p.basename(localization));
      final extension = p.extension(source) == '.storyboard'
          ? '.storyboardc'
          : '.nib';
      await StoryboardCompiler().compileFile(
        relocated,
        p.join(directory, p.basenameWithoutExtension(source) + extension),
      );
      continue;
    }

    if (p.extension(source) == '.storyboard') {
      source = p.setExtension(source, '.storyboardc');
    } else if (strict && p.extension(source) == '.xib') {
      source = p.setExtension(source, '.nib');
    }

    var sourceType = FileSystemEntity.typeSync(source, followLinks: false);
    if (sourceType == FileSystemEntityType.notFound) {
      final relocated = _findRelocatedResource(projectRoot, source);
      if (relocated == null) {
        if (strict) {
          throw FlutterBuildError(
            'Required release resource is missing: $source. Storyboards/XIBs need precompiled ibtool output.',
          );
        }
        continue;
      }
      source = relocated;
      sourceType = FileSystemEntity.typeSync(source, followLinks: false);
    }

    final localization = _nearestLocalization(source);
    final isBaseStoryboard =
        p.extension(source) == '.storyboardc' &&
        localization != null &&
        p.basename(localization) == 'Base.lproj';
    final destinationDirectory = localization == null || isBaseStoryboard
        ? bundleDir
        : p.join(bundleDir, p.basename(localization));
    final destination = p.join(destinationDirectory, p.basename(source));
    await Directory(destinationDirectory).create(recursive: true);

    if (sourceType == FileSystemEntityType.directory) {
      final existing = Directory(destination);
      if (existing.existsSync()) await existing.delete(recursive: true);
      await copyDirectoryPreservingSymlinks(source, destination);
    } else if (sourceType == FileSystemEntityType.file) {
      await File(source).copy(destination);
    }
  }
  return assetPlist;
}

String? _findRelocatedResource(String projectRoot, String unresolved) {
  final ios = Directory(p.join(projectRoot, 'ios'));
  if (!ios.existsSync()) return null;
  final name = p.basename(unresolved);
  final matches = ios
      .listSync(recursive: true, followLinks: false)
      .where((entity) => p.basename(entity.path) == name)
      .map((entity) => entity.path)
      .toList();
  return matches.length == 1 ? matches.single : null;
}

String? _resolveBuildSettingPath(PbxProject project, String? value) {
  if (value == null || value.isEmpty || value.contains(r'$')) return null;
  return p.normalize(
    p.isAbsolute(value) ? value : p.join(project.projectDirectory, value),
  );
}

String? _nearestLocalization(String path) {
  var directory = p.dirname(path);
  while (directory != p.dirname(directory)) {
    if (p.extension(directory) == '.lproj') return directory;
    directory = p.dirname(directory);
  }
  return null;
}
