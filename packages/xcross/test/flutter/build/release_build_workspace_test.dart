import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/internal/release_build_workspace.dart';

void main() {
  late Directory project;
  setUp(
    () => project = Directory.systemTemp.createTempSync('release-workspace-'),
  );
  tearDown(() => project.delete(recursive: true));

  File write(String path, String contents) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);

  test(
    'retains symbols and packaged output, removes only its intermediates',
    () async {
      final output = p.join(project.path, 'intermediates');
      final sibling = write(
        p.join(output, 'build-other', 'keep'),
        'other build',
      );
      late String temporary;
      final result = await withReleaseBuildWorkspace(output, (build) async {
        temporary = build.path;
        write(p.join(build.path, 'app.dill'), 'kernel');
        final binary = write(
          p.join(build.path, 'App.framework', 'App'),
          'binary',
        );
        write(
          p.join(
            build.path,
            'App.framework.dSYM',
            'Contents',
            'Resources',
            'DWARF',
            'App',
          ),
          'app symbols',
        );
        write(
          p.join(build.path, 'native_assets', 'Native.framework.dSYM', 'DWARF'),
          'native symbols',
        );
        write(p.join(build.path, 'release-evidence.json'), '{}');
        final symbols = p.join(project.path, 'symbols', 'uuid');
        await preserveReleaseSymbols(build, symbols);
        final packaged = p.join(project.path, 'packaged');
        await binary.copy(packaged);
        return packaged;
      });
      expect(File(result).readAsStringSync(), 'binary');
      expect(Directory(temporary).existsSync(), isFalse);
      expect(sibling.readAsStringSync(), 'other build');
      expect(
        File(
          p.join(
            project.path,
            'symbols',
            'uuid',
            'App.framework.dSYM',
            'Contents',
            'Resources',
            'DWARF',
            'App',
          ),
        ).readAsStringSync(),
        'app symbols',
      );
      expect(
        File(
          p.join(
            project.path,
            'symbols',
            'uuid',
            'native_assets',
            'Native.framework.dSYM',
            'DWARF',
          ),
        ).readAsStringSync(),
        'native symbols',
      );
      expect(
        File(p.join(project.path, 'symbols', 'uuid', 'app.dill')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'waits for asynchronous packaging and cleans up after failure',
    () async {
      final packaging = Completer<void>();
      final ready = Completer<Directory>();
      final build = withReleaseBuildWorkspace(project.path, (directory) async {
        write(p.join(directory.path, 'request.json'), 'sensitive define');
        ready.complete(directory);
        await packaging.future;
        throw StateError('packaging failed');
      });
      final directory = await ready.future;
      expect(directory.existsSync(), isTrue);
      final failure = expectLater(build, throwsStateError);
      packaging.complete();
      await failure;
      expect(directory.existsSync(), isFalse);
    },
  );
}
