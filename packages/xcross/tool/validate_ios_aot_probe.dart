import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

import 'ios_aot/snapshotter_builder.dart';
import 'ios_aot/snapshotter_context.dart';
import 'ios_aot/snapshotter_inspection.dart';

/// Independent LLVM/dSYM and release-engine checks; no device acceptance claim.
Future<void> main() async {
  final context = SnapshotterContext(findSnapshotterRepository());
  await context.locked(() async {
    final output = p.join(context.cache, 'probe');
    final binary = p.join(output, 'App.framework', 'App');
    final snapshotter = p.join(
      context.source,
      'out',
      'ios_aot_product',
      '${context.target}${context.suffix}',
    );
    final snapshotHash = await context.run(await snapshotterPython(context), [
      p.join(context.source, 'tools', 'make_version.py'),
      '--format={{SNAPSHOT_HASH}}',
    ], cwd: context.source);
    requireSnapshotter(
      snapshotHash == context.pins['snapshotHash'],
      'Pinned snapshot source hash changed',
    );
    final report = <String, Object>{
      'compilation': auditSnapshotterCommands(
        jsonDecode(
              await File(
                p.join(
                  context.source,
                  'out',
                  'ios_aot_product',
                  'compile_commands.json',
                ),
              ).readAsString(),
            )
            as List<dynamic>,
        context.host,
      ),
      'host': inspectSnapshotterHost(
        await File(snapshotter).readAsBytes(),
        context.host,
      ),
      'macho': inspectSnapshotterProduct(
        await File(binary).readAsBytes(),
        snapshotHash,
      ),
    };
    final archive = await context.download('ios-release.zip');
    final engineDir = p.join(context.cache, 'ios-release');
    final engine = p.join(
      engineDir,
      'Flutter.xcframework',
      'ios-arm64',
      'Flutter.framework',
      'Flutter',
    );
    if (!File(engine).existsSync()) await context.extract(archive, engineDir);
    requireSnapshotter(
      latin1.decode(await File(engine).readAsBytes()).contains(snapshotHash),
      'Release engine does not contain expected snapshot hash',
    );
    report['engine'] = {
      'artifactKey': context.pins['engineArtifactKey'],
      'zipSha256': await fileSha256(archive),
      'binarySha256': await fileSha256(engine),
      'snapshotHashPresent': snapshotHash,
    };
    Future<String> tool(String name) async {
      final executable = await ProcessRunner.which('$name${context.suffix}');
      if (executable == null) {
        throw StateError('Missing verification tool: $name');
      }
      return executable;
    }

    for (final entry in [
      ('app-headers', 'llvm-objdump', ['--macho', '--private-headers', binary]),
      ('app-symbols', 'llvm-nm', ['-g', binary]),
      (
        'engine-headers',
        'llvm-objdump',
        ['--macho', '--private-headers', engine],
      ),
      ('host-headers', 'llvm-readobj', ['--file-headers', snapshotter]),
      (
        'object-headers',
        'llvm-objdump',
        ['--macho', '--private-headers', p.join(output, 'app.o')],
      ),
    ]) {
      await context.run(
        await tool(entry.$2),
        entry.$3,
        cwd: output,
        log: p.join(output, '${entry.$1}.txt'),
      );
    }
    final dsym = p.join(output, 'App.framework.dSYM');
    final dwarf = p.join(dsym, 'Contents', 'Resources', 'DWARF', 'App');
    await context.assertPrivate(dsym);
    await context.assertPrivate(dwarf);
    await context.run(
      await tool('dsymutil'),
      ['-o', dsym, binary],
      cwd: output,
      log: p.join(output, 'dsymutil.log'),
    );
    requireSnapshotter(
      await File(dwarf).length() > 0,
      'dsymutil produced no DWARF',
    );
    final uuids = <String>[];
    for (final entry in [(binary, 'app'), (dwarf, 'dsym')]) {
      final text = await context.run(await tool('llvm-dwarfdump'), [
        '--uuid',
        entry.$1,
      ], cwd: output);
      await context.writeText(p.join(output, '${entry.$2}-uuid.txt'), text);
      final match = RegExp('UUID: ([0-9A-Fa-f-]+)').firstMatch(text);
      requireSnapshotter(match != null, 'Missing Mach-O UUID');
      uuids.add(match![1]!.toLowerCase());
    }
    requireSnapshotter(uuids[0] == uuids[1], 'dSYM UUID does not match App');
    await context.run(
      await tool('llvm-dwarfdump'),
      ['--verify', dwarf],
      cwd: output,
      log: p.join(output, 'dwarf-verify.txt'),
    );
    final stripped = p.join(output, 'App.stripped');
    await context.assertPrivate(stripped);
    await context.run(
      await tool('llvm-strip'),
      ['-x', binary, '-o', stripped],
      cwd: output,
      log: p.join(output, 'strip.log'),
    );
    report['stripped'] = inspectSnapshotterProduct(
      await File(stripped).readAsBytes(),
      snapshotHash,
    );
    report['dwarf'] = {
      'uuid': uuids[0],
      'sha256': await fileSha256(dwarf),
      'size': await File(dwarf).length(),
    };
    report['limits'] = [
      'No signing, installation or device execution verified by this tool',
    ];
    await context.writeJson(p.join(output, 'validation.json'), report);
    stdout.writeln(
      'Structural and LLVM checks passed; device acceptance is a separate check.',
    );
  });
}
