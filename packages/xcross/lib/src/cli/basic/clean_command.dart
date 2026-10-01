import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';

final class CleanCommand extends Command<void> {
  @override
  String get name => 'clean';

  @override
  String get description => 'Clear xcross build caches for this workspace.';

  @override
  Future<void> run() async {
    final removed = await cleanProject(Directory.current.path);
    for (final path in removed) {
      Log.logStatus('Removed $path');
    }
    return removed.isEmpty
        ? Log.logStatus('No xcross build caches found')
        : Log.logDone('Clean complete');
  }

  static Future<List<String>> cleanProject(
    String projectRoot, {
    Map<String, String>? environment,
  }) async {
    final paths = [
      p.join(projectRoot, 'build', 'xcross-native-assets'),
      for (final mode in FlutterBuildMode.values)
        SwiftPmWorkspace.forProject(
          projectRoot,
          environment: environment,
          mode: mode,
        ).root,
    ];
    final removed = <String>[];
    for (final path in paths) {
      final directory = Directory(path);
      if (!directory.existsSync()) continue;
      await directory.delete(recursive: true);
      removed.add(path);
    }
    return removed;
  }
}
