import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/ios_aot_toolchain.dart';
import 'package:xcross/src/flutter/errors.dart';

void main() {
  late Directory root;
  late String launcher;
  late File manifest;
  late File binary;
  setUp(() {
    root = Directory.systemTemp.createTempSync('aot bundle ü ');
    launcher = p.join(root.path, 'bin', 'xcross');
    final lib = Directory(p.join(root.path, 'lib'))..createSync();
    manifest = File(p.join(lib.path, IosAotToolchain.manifestName));
    binary = File(p.join(lib.path, 'snapshotter'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  void seed(Abi abi) {
    final bytes = Uint8List(128);
    final data = ByteData.sublistView(bytes);
    if (abi == Abi.windowsX64) {
      data.setUint16(0, 0x5a4d, Endian.little);
      data.setUint32(60, 64, Endian.little);
      data.setUint32(64, 0x4550, Endian.little);
      data.setUint16(68, 0x8664, Endian.little);
      data.setUint16(86, 2, Endian.little);
    } else {
      bytes.setAll(0, [0x7f, 69, 76, 70, 2, 1, 1]);
      data.setUint16(16, 3, Endian.little);
      data.setUint16(18, abi == Abi.linuxX64 ? 62 : 183, Endian.little);
      data.setUint64(24, 0x1000, Endian.little);
    }
    binary.writeAsBytesSync(bytes);
    manifest.writeAsStringSync(
      jsonEncode({
        'pins': {
          'flutterRevision': IosAotToolchain.flutterRevision,
          'engineArtifactKey': IosAotToolchain.engineRevision,
          'dartRevision': IosAotToolchain.dartRevision,
          'snapshotHash': IosAotToolchain.snapshotHash,
        },
        'host': {'host': abi.toString().replaceAll('_', '-')},
        'binaryRelativePath': 'snapshotter',
        'binarySha256': sha256.convert(bytes).toString(),
      }),
    );
  }

  Future<IosAotToolchain> load(Abi abi, {Map<String, String> env = const {}}) =>
      IosAotToolchain.loadCompiler(
        launcherPath: launcher,
        environment: env,
        hostAbi: abi,
      );

  for (final abi in [Abi.windowsX64, Abi.linuxX64, Abi.linuxArm64]) {
    test(
      'finds bundled $abi compiler without environment configuration',
      () async {
        seed(abi);
        expect((await load(abi)).executable, binary.path);
      },
    );
  }
  test(
    'explicit missing override never falls back to bundled compiler',
    () async {
      seed(Abi.windowsX64);
      await expectLater(
        load(
          Abi.windowsX64,
          env: {'XCROSS_IOS_AOT_MANIFEST': p.join(root.path, 'missing.json')},
        ),
        throwsA(isA<FlutterBuildError>()),
      );
    },
  );
  test('rejects wrong host, corruption and incompatible revision', () async {
    seed(Abi.linuxArm64);
    await expectLater(load(Abi.linuxX64), throwsA(isA<FlutterBuildError>()));
    seed(Abi.linuxX64);
    binary.writeAsBytesSync([...binary.readAsBytesSync(), 1]);
    await expectLater(load(Abi.linuxX64), throwsA(isA<FlutterBuildError>()));
    seed(Abi.linuxX64);
    manifest.writeAsStringSync(
      manifest.readAsStringSync().replaceAll(
        IosAotToolchain.dartRevision,
        'incompatible',
      ),
    );
    await expectLater(load(Abi.linuxX64), throwsA(isA<FlutterBuildError>()));
  });
  test('rejects executable paths outside manifest directory', () async {
    seed(Abi.linuxX64);
    manifest.writeAsStringSync(
      manifest.readAsStringSync().replaceAll(
        '"binaryRelativePath":"snapshotter"',
        '"binaryRelativePath":"../outside"',
      ),
    );
    await expectLater(load(Abi.linuxX64), throwsA(isA<FlutterBuildError>()));
  });
}
