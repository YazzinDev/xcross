import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;

import 'snapshotter_context.dart';
import 'snapshotter_inspection.dart';

String findSnapshotterClang(String host, {String? path}) {
  final windows = host == 'windows-x64';
  final compiler = windows ? 'clang-cl.exe' : 'clang';
  final required = windows
      ? [compiler, 'lld-link.exe', 'llvm-lib.exe']
      : [
          compiler,
          'clang++',
          'llvm-ar',
          'llvm-nm',
          'llvm-objcopy',
          'llvm-readelf',
          'ld.lld',
        ];
  // Swift may precede LLVM on PATH but omit nm/objcopy needed by this build.
  // Select a complete installation instead of mixing unrelated toolchains.
  final directories = {
    ...(path ?? Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    ),
    if (path == null) ...DarwinSdk.llvmToolDirs(),
  };
  for (final entry in directories) {
    if (entry.isEmpty) continue;
    final candidate = File(p.join(entry, compiler));
    if (!candidate.existsSync()) continue;
    final root = p.dirname(p.dirname(candidate.resolveSymbolicLinksSync()));
    if (required.every(
      (tool) => File(p.join(root, 'bin', tool)).existsSync(),
    )) {
      return root;
    }
  }
  throw StateError(
    'Install the complete LLVM/Clang/LLD toolchain and place its bin directory on PATH',
  );
}

/// Only GN/upstream Dart build scripts need Python. xcross's orchestration,
/// downloads, private patches, auditing and publication are Dart code.
Future<String> snapshotterPython(
  SnapshotterContext context, [
  String? selected,
]) async {
  final candidates = <String>{
    if (selected != null)
      selected
    else
      for (final name in ['python3', 'python', if (Platform.isWindows) 'py'])
        if (await ProcessRunner.which(name) case final String executable)
          executable,
  };
  for (final candidate in candidates) {
    try {
      // Resolve launchers such as py.exe to the actual interpreter used by GN.
      final result =
          jsonDecode(
                await context.run(candidate, [
                  '-c',
                  'import json,sys; print(json.dumps([sys.executable,sys.version_info.major,sys.version_info.minor]))',
                ]),
              )
              as List<dynamic>;
      if (result[1] == 3 && (result[2] as int) >= 10) {
        return p.absolute(result[0] as String);
      }
    } on Object {
      // An unusable alias must not hide another installed interpreter.
    }
  }
  if (selected != null) {
    throw StateError(
      'Dart source builds require Python 3.10+; unusable interpreter at $selected.',
    );
  }
  return prepareSnapshotterPython(context);
}

/// Supply a private interpreter when normal setup's Python is absent or older.
/// Upstream licenses remain in the extracted distribution; nothing is installed
/// into the user's PATH or global Python environments.
Future<String> prepareSnapshotterPython(SnapshotterContext context) async {
  final archive = await context.download('python-${context.host}.tar.gz');
  final digest = await fileSha256(archive);
  final directory = p.join(context.cache, 'python-$digest');
  final executable = p.join(
    directory,
    context.windows ? 'python.exe' : 'bin/python3.13',
  );
  if (!File(executable).existsSync()) {
    await context.extract(
      archive,
      directory,
      memberRoot: 'python',
      // The actual interpreter is a regular file. Unix alias symlinks are
      // unnecessary because GN receives its absolute, versioned path.
      skipSymbolicLinks: true,
    );
  }
  await context.run(executable, ['--version']);
  return executable;
}

final class SnapshotterBuilder {
  SnapshotterBuilder(this.context);
  final SnapshotterContext context;

  Future<void> build({
    String? packageOutput,
    String? clangRoot,
    String? visualStudio,
    String? python,
    int jobs = 2,
    bool configureOnly = false,
  }) => context.locked(() async {
    if (context.host != snapshotterHost()) {
      throw StateError('Compiler must be built on its native host.');
    }
    if (jobs <= 0) throw ArgumentError('jobs must be positive');
    final clang = clangRoot ?? findSnapshotterClang(context.host);
    final scriptExecutable = await snapshotterPython(context, python);
    var vs = visualStudio;
    if (context.windows && vs == null) {
      final vswhere = p.join(
        Platform.environment['ProgramFiles(x86)'] ?? 'C:/Program Files (x86)',
        'Microsoft Visual Studio',
        'Installer',
        'vswhere.exe',
      );
      vs = await context.run(vswhere, [
        '-latest',
        '-products',
        '*',
        '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property',
        'installationPath',
      ]);
      if (!Directory(p.join(vs, 'VC')).existsSync()) {
        throw StateError(
          'Install Visual Studio C++ desktop build tools and Windows SDK',
        );
      }
    }
    final gn = await prepare();
    final out = p.join(context.source, 'out', 'ios_aot_product');
    final args = <String, Object>{
      'target_os': context.windows ? 'win' : 'linux',
      'target_cpu': context.host.split('-').last,
      'is_clang': true,
      'is_debug': false,
      'is_release': true,
      'is_product': true,
      'dart_debug': false,
      'dart_runtime_mode': 'release',
      'dart_use_compressed_pointers': false,
      'dart_support_perfetto': false,
      'dart_dynamic_modules': false,
      'dart_sdk_verification_hash': (context.pins['dartRevision'] as String)
          .substring(0, 10),
      context.windows
          ? 'clang_base_path'
          : 'clang_prefix': (context.windows ? clang : p.join(clang, 'bin'))
          .replaceAll(r'\', '/'),
      if (!context.windows)
        'xcross_host_toolchain_sha256': await fileSha256(
          p.join(clang, 'bin', 'clang'),
        ),
    };
    final argsPath = p.join(out, 'args.gn');
    await context.writeText(
      argsPath,
      '${args.entries.map((e) => '${e.key} = ${jsonEncode(e.value)}').join('\n')}\n',
    );
    final environment = <String, String>{
      if (context.windows) 'DEPOT_TOOLS_WIN_TOOLCHAIN': '0',
      if (context.windows) 'GYP_MSVS_OVERRIDE_PATH': vs!,
    };
    await context.run(
      gn,
      [
        'gen',
        out,
        '--root-target=//runtime/bin:${context.target}',
        '--root-pattern=//runtime/bin:${context.target}',
        '--script-executable=$scriptExecutable',
        '--export-compile-commands',
      ],
      cwd: context.source,
      environment: environment,
      log: p.join(context.cache, 'configure.log'),
    );
    if (configureOnly) return;
    final ninja = p.join(
      context.source,
      'buildtools',
      'ninja',
      'ninja${context.suffix}',
    );
    await context.run(
      ninja,
      ['-C', out, '-j', '$jobs', context.target],
      cwd: context.source,
      environment: environment,
      log: p.join(context.cache, 'build.log'),
    );
    final binary = p.join(out, '${context.target}${context.suffix}');
    final commands = p.join(out, 'compile_commands.json');
    final evidence = <String, Object>{
      'pins': context.pins,
      'host': inspectSnapshotterHost(
        await File(binary).readAsBytes(),
        context.host,
      ),
      'configuration': auditSnapshotterCommands(
        jsonDecode(await File(commands).readAsString()) as List<dynamic>,
        context.host,
      ),
      'binarySha256': await fileSha256(binary),
      'patchSha256': await fileSha256(
        p.join(context.cache, 'snapshotter.patch'),
      ),
      'compileCommandsSha256': await fileSha256(commands),
      'gnArgs': await File(argsPath).readAsString(),
    };
    for (final entry in {
      'clang': p.join(clang, 'bin', context.windows ? 'clang-cl.exe' : 'clang'),
      'gn': gn,
      'ninja': ninja,
      'snapshotter': binary,
    }.entries) {
      evidence[entry.key] = {
        'version': await context.run(entry.value, ['--version']),
        'executableSha256': await fileSha256(entry.value),
      };
    }
    await publish(binary, evidence);
    if (packageOutput != null) await package(binary, evidence, packageOutput);
    stdout.writeln(
      'Snapshotter built and audited. Device acceptance is a separate check.',
    );
  });

  Future<String> prepare() async {
    await context.assertPrivate(context.source);
    final sourceArchive = await context.download('dart-b530c21.tar.gz');
    if (!Directory(context.source).existsSync()) {
      await context.extract(
        sourceArchive,
        context.source,
        memberRoot: p.basename(context.source),
      );
    }
    // Real Git metadata binds the upstream version generator to the pinned SDK,
    // rather than accidentally reading xcross's HEAD. Never fetch into an SDK.
    await context.assertPrivate(p.join(context.source, '.git'));
    if (!Directory(p.join(context.source, '.git')).existsSync()) {
      await context.run('git', ['init'], cwd: context.source);
    }
    await context.run('git', [
      'config',
      'core.autocrlf',
      'false',
    ], cwd: context.source);
    final revision = await Process.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: context.source);
    final pin = context.pins['dartRevision'] as String;
    if (revision.exitCode != 0) {
      await context.run('git', [
        'fetch',
        '--depth=1',
        'https://github.com/dart-lang/sdk.git',
        pin,
      ], cwd: context.source);
      await context.run('git', [
        'update-ref',
        'HEAD',
        pin,
      ], cwd: context.source);
      await context.run('git', ['read-tree', pin], cwd: context.source);
    } else if ('${revision.stdout}'.trim() != pin) {
      throw StateError('Private Dart checkout is at an unexpected revision');
    }
    await applyPatches();
    for (final dependency in [
      (name: 'zlib', path: 'third_party/zlib', marker: 'zlib.h'),
      (name: 'icu', path: 'third_party/icu', marker: 'BUILD.gn'),
      (
        name: 'boringssl',
        path: 'third_party/boringssl/src',
        marker: 'gen/sources.gni',
      ),
    ]) {
      final archive = await context.download('${dependency.name}.tar.gz');
      final destination = p.join(context.source, dependency.path);
      if (!File(p.join(destination, dependency.marker)).existsSync()) {
        await context.extract(archive, destination);
      }
    }
    final tag = context.windows
        ? ''
        : '-${context.host.replaceAll('x64', 'amd64')}';
    final gnZip = await context.download('gn$tag.zip');
    final gn = p.join(context.cache, 'gn$tag', 'gn${context.suffix}');
    if (!File(gn).existsSync()) await context.extract(gnZip, p.dirname(gn));
    await context.executable(gn);
    final ninjaZip = await context.download('ninja$tag.zip');
    final ninja = p.join(
      context.source,
      'buildtools',
      'ninja',
      'ninja${context.suffix}',
    );
    if (!File(ninja).existsSync()) {
      await context.extract(ninjaZip, p.dirname(ninja));
    }
    await context.executable(ninja);
    // The sole gclient_gn_args entry in pinned DEPS; DevTools is not built.
    await context.writeText(
      p.join(context.source, 'build/config/gclient_args.gni'),
      'build_devtools_from_sources = false\n',
    );
    return gn;
  }

  Future<void> applyPatches() async {
    final host = context.windows ? 'windows' : 'linux';
    final patchRoot = p.join(context.recipe, 'patches');
    final spec =
        readObject(p.join(patchRoot, 'manifest.json'))[host]
            as Map<String, dynamic>;
    final patch = p.join(patchRoot, '$host.patch');
    requireSnapshotter(
      await fileSha256(patch) == spec['patchSha256'],
      'Pinned patch checksum mismatch',
    );
    final files = spec['files'] as Map<String, dynamic>;
    // Validate every destination before changing any of them. Interrupted builds
    // may contain a mix of pristine and already-patched files; both are known.
    final pending = <String>[];
    for (final entry in files.entries) {
      final path = p.join(context.source, entry.key);
      await context.assertPrivate(path);
      final hashes = entry.value as Map<String, dynamic>;
      final current = await fileSha256(path);
      if (current == hashes['patchedSha256']) continue;
      requireSnapshotter(
        current == hashes['originalSha256'],
        'Unexpected source changes: $path',
      );
      pending.add(entry.key);
    }
    for (final relative in pending) {
      await context.run('git', [
        '-c',
        'core.autocrlf=false',
        'apply',
        '--include=$relative',
        patch,
      ], cwd: context.source);
      final expected =
          (files[relative] as Map<String, dynamic>)['patchedSha256'];
      requireSnapshotter(
        await fileSha256(p.join(context.source, relative)) == expected,
        'Patched source checksum mismatch: $relative',
      );
    }
    await context.write(
      p.join(context.cache, 'snapshotter.patch'),
      await File(patch).readAsBytes(),
    );
  }

  Future<void> publish(String binary, Map<String, Object> evidence) async {
    // Immutable content-addressed executables remain usable during a rebuild.
    final digest = await fileSha256(binary);
    final target = p.join(
      context.cache,
      'snapshotters',
      '$digest${context.suffix}',
    );
    await context.assertPrivate(target);
    if (!File(target).existsSync()) {
      await context.write(target, await File(binary).readAsBytes());
    }
    requireSnapshotter(
      await fileSha256(target) == digest,
      'Corrupt content-addressed snapshotter',
    );
    await context.executable(target);
    evidence['binaryRelativePath'] = p
        .relative(target, from: context.cache)
        .replaceAll(r'\', '/');
    await context.writeJson(
      p.join(context.cache, 'snapshotter-manifest.json'),
      evidence,
    );
  }

  Future<void> package(
    String binary,
    Map<String, Object> evidence,
    String destination,
  ) async {
    // Flat lib entries are understood by the existing transactional updater.
    final name = 'gen_snapshot_ios_arm64${context.suffix}';
    final manifest = {...evidence, 'binaryRelativePath': name};
    final notices = StringBuffer();
    for (final relative in [
      'LICENSE',
      'third_party/zlib/LICENSE',
      'third_party/icu/LICENSE',
      'third_party/boringssl/src/LICENSE',
      'third_party/double-conversion/LICENSE',
      'third_party/double-conversion/COPYING',
    ]) {
      notices.writeln(
        '$relative\n${await File(p.join(context.source, relative)).readAsString()}\n',
      );
    }
    await Directory(destination).create(recursive: true);
    for (final entry in <String, List<int>>{
      name: await File(binary).readAsBytes(),
      'ios-aot-NOTICES.txt': utf8.encode(notices.toString()),
      'xcross-ios-aot-manifest.json': utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      ),
    }.entries) {
      final target = p.join(destination, entry.key);
      final pending = File('$target.part');
      await pending.writeAsBytes(entry.value, flush: true);
      await pending.rename(target);
    }
    if (!Platform.isWindows) {
      await context.run('chmod', ['755', '--', p.join(destination, name)]);
    }
  }
}
