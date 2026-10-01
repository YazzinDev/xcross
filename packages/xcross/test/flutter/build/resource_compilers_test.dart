import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/flutter/build/info_plist.dart';
import 'package:xcross/src/flutter/build/resources/asset_catalog_compiler.dart';
import 'package:xcross/src/flutter/build/resources/storyboard_compiler.dart';
import 'package:xcross/src/flutter/errors.dart';

// Independent synthetic input: no application-specific names or source files.
const storyboard = '''
<document targetRuntime="iOS.CocoaTouch" initialViewController="controller" useAutolayout="YES">
 <scenes><scene sceneID="scene"><objects>
  <viewController id="controller" customClass="FlutterViewController" storyboardIdentifier="Entry">
   <view key="view" id="root"><rect key="frame" x="0" y="0" width="320" height="480"/>
    <subviews><imageView id="image" image="Symbol" contentMode="center" translatesAutoresizingMaskIntoConstraints="NO"/></subviews>
    <constraints><constraint firstItem="image" firstAttribute="centerX" secondItem="root" secondAttribute="centerX" constant="0" id="center"/></constraints>
   </view>
  </viewController>
  <placeholder placeholderIdentifier="IBFirstResponder" id="responder"/>
 </objects></scene></scenes></document>''';

void main() {
  final compiler = StoryboardCompiler();
  test(
    'missing declared storyboards fail instead of becoming blank launch screens',
    () async {
      final bundle = await Directory.systemTemp.createTemp(
        'xcross-storyboard-ref-',
      );
      addTearDown(() => bundle.delete(recursive: true));
      const plist =
          '<plist><dict><key>UILaunchStoryboardName</key><string>Launch</string></dict></plist>';
      expect(
        () => InfoPlist.validateStoryboardReferences(plist, bundle.path),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('will not replace'),
          ),
        ),
      );
      final info = File(
        p.join(bundle.path, 'en.lproj', 'Launch.storyboardc', 'Info.plist'),
      );
      await info.parent.create(recursive: true);
      await info.writeAsString('<plist><dict/></plist>');
      expect(
        () => InfoPlist.validateStoryboardReferences(plist, bundle.path),
        returnsNormally,
      );
    },
  );
  test(
    'emits a loadable storyboard graph with image, constraint and entry point',
    () {
      final output = compiler.compile(storyboard, source: 'Example.storyboard');
      final info =
          PropertyListSerialization.propertyListWithString(
                utf8.decode(output['Info.plist']!),
              )
              as Map;
      final entry = info['UIStoryboardDesignatedEntryPointIdentifier'];
      expect(entry, 'Entry');
      final scene =
          (info['UIViewControllerIdentifiersToNibNames'] as Map)[entry];
      expect(output, contains('$scene.nib'));
      final records = output.entries
          .where((e) => e.key.endsWith('.nib'))
          .expand((e) => readNib(e.value))
          .toList();
      expect(
        records.where((o) => o.$1 == 'UIImageNibPlaceholder'),
        hasLength(1),
      );
      expect(records.where((o) => o.$1 == 'NSLayoutConstraint'), hasLength(1));
      expect(records.where((o) => o.$1 == 'UIClassSwapper'), hasLength(1));
      final strings = records
          .where((o) => o.$1 == 'NSString')
          .map((o) => utf8.decode(o.$2['NS.bytes']! as Uint8List));
      expect(strings, containsAll(['Symbol', 'FlutterViewController']));
      expect(output.keys, contains('$scene.nib'));
      final again = compiler.compile(storyboard, source: 'Example.storyboard');
      for (final file in output.keys) {
        expect(again[file], output[file]);
      }
    },
  );
  for (final mutation in <String, String>{
    'unknown element': storyboard.replaceFirst(
      '<subviews>',
      '<subviews><stackView id="unsupported"/>',
    ),
    'unknown attribute': storyboard.replaceFirst(
      'id="image"',
      'id="image" semanticContentAttribute="forceRightToLeft"',
    ),
    'unknown enum': storyboard.replaceFirst(
      'contentMode="center"',
      'contentMode="invented"',
    ),
    'unknown reference': storyboard.replaceFirst(
      'secondItem="root"',
      'secondItem="missing"',
    ),
    'non-view constraint target': storyboard.replaceFirst(
      'secondItem="root"',
      'secondItem="controller"',
    ),
    'unrepresentable integer': storyboard.replaceFirst(
      'id="image"',
      'id="image" tag="4294967296"',
    ),
    'unsupported multiplier': storyboard.replaceFirst(
      'constant="0"',
      'constant="0" multiplier="2"',
    ),
    'invalid parent': storyboard.replaceFirst(
      '<subviews>',
      '<subviews><color key="backgroundColor" white="1"/>',
    ),
    'duplicate id': storyboard.replaceFirst('id="image"', 'id="root"'),
    'non-finite number': storyboard.replaceFirst('width="320"', 'width="NaN"'),
    'unconsumed scene object': storyboard.replaceFirst(
      '</objects>',
      '<view id="orphan"/></objects>',
    ),
    'unconsumed placeholder outlet': storyboard.replaceFirst(
      'id="responder"/>',
      'id="responder"><connections><outlet property="view" destination="root"/></connections></placeholder>',
    ),
    'duplicate subviews': storyboard.replaceFirst(
      '</subviews>',
      '</subviews><subviews/>',
    ),
    'custom launch class': storyboard.replaceFirst(
      '<document ',
      '<document launchScreen="YES" ',
    ),
    'unknown color space': storyboard.replaceFirst(
      '<subviews>',
      '<color key="backgroundColor" colorSpace="unsupported"/><subviews>',
    ),
  }.entries) {
    test('rejects ${mutation.key} with a source-qualified diagnostic', () {
      expect(
        () => compiler.compile(mutation.value, source: 'Input.storyboard'),
        throwsA(
          isA<FlutterBuildError>().having(
            (e) => e.message,
            'message',
            contains('Input.storyboard'),
          ),
        ),
      );
    });
  }
  test('compiles standalone XIB with a files-owner outlet', () {
    const xml = '''
<document targetRuntime="iOS.CocoaTouch"><objects>
      <placeholder placeholderIdentifier="IBFilesOwner" id="owner"><connections><outlet property="view" destination="content" id="connection"/></connections></placeholder>
      <view id="content"><rect key="frame" x="0" y="0" width="90" height="40"/></view>
      </objects></document>''';
    final records = readNib(compiler.compile(xml, source: 'Panel.xib')['']!);
    expect(
      records.where((o) => o.$1 == 'UIRuntimeOutletConnection'),
      hasLength(1),
    );
    expect(records.where((o) => o.$1 == 'UIView'), hasLength(1));
  });
  test('preserves scene storyboard through native lifecycle configuration', () {
    const xml = '''
<plist version="1.0"><dict><key>UIMainStoryboardFile</key><string>Main</string>
      <key>UIApplicationSceneManifest</key><dict><key>UISceneConfigurations</key><dict>
      <key>UIWindowSceneSessionRoleApplication</key><array><dict>
      <key>UISceneStoryboardFile</key><string>Alternate</string></dict></array></dict></dict></dict></plist>''';
    final result = InfoPlist.applySceneLifecycle(xml);
    expect(
      result,
      contains('<key>UISceneStoryboardFile</key><string>Alternate</string>'),
    );
    expect(InfoPlist.applySceneLifecycle(result), result);
  });
  test('merges catalog icon dictionaries without losing app keys', () {
    const app =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict><key>CFBundleIcons</key><dict/><key>Other</key><string>kept</string></dict></plist>';
    const icons =
        '<plist><dict><key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconName</key><string>Example</string></dict></dict></dict></plist>';
    final result = InfoPlist.mergeAssetMetadata(app, icons);
    final parsed =
        PropertyListSerialization.propertyListWithString(result) as Map;
    expect(parsed['Other'], 'kept');
    expect((parsed['CFBundleIcons'] as Map)['CFBundlePrimaryIcon'], {
      'CFBundleIconName': 'Example',
    });
  });
  test(
    'keeps all application storyboard configurations and external roles',
    () {
      const xml = '''
<plist><dict><key>UIApplicationSceneManifest</key><dict><key>UISceneConfigurations</key><dict>
<key>UIWindowSceneSessionRoleExternalDisplay</key><array><dict><key>UISceneStoryboardFile</key><string>External</string></dict></array>
<key>UIWindowSceneSessionRoleApplication</key><array>
<dict><key>UISceneConfigurationName</key><string>First</string><key>UISceneStoryboardFile</key><string>One</string></dict>
<dict><key>UISceneConfigurationName</key><string>Second</string><key>UISceneStoryboardFile</key><string>Two</string></dict>
</array></dict></dict></dict></plist>''';
      final result = InfoPlist.applySceneLifecycle(xml);
      expect(result, contains('<string>One</string>'));
      expect(result, contains('<string>Two</string>'));
      expect(result, contains('<string>External</string>'));
      expect('UISceneDelegateClassName'.allMatches(result), hasLength(2));
      expect(InfoPlist.applySceneLifecycle(result), result);
    },
  );
  test(
    'catalog validation rejects unsupported metadata and escaping files',
    () async {
      final root = await Directory.systemTemp.createTemp('xcross-catalog-');
      addTearDown(() => root.delete(recursive: true));
      final image = Directory(p.join(root.path, 'Example.imageset'))
        ..createSync();
      final file = File(p.join(image.path, 'Contents.json'));
      file.writeAsStringSync(
        '{"images":[],"properties":{"preserves-vector-representation":true}}',
      );
      expect(
        () => AssetCatalogCompiler().validate(root.path),
        throwsA(isA<FlutterBuildError>()),
      );
      file.writeAsStringSync(
        '{"images":[{"filename":"../outside.png","idiom":"universal"}]}',
      );
      expect(
        () => AssetCatalogCompiler().validate(root.path),
        throwsA(isA<FlutterBuildError>()),
      );
    },
  );
  test('rejects colliding asset names before preparing native tools', () async {
    final root = await Directory.systemTemp.createTemp('xcross-collision-');
    addTearDown(() => root.delete(recursive: true));
    final catalogs = <String>[];
    for (final name in ['Image1623', 'Image8000']) {
      final catalog = Directory(p.join(root.path, '$name.xcassets'));
      final image = Directory(p.join(catalog.path, '$name.imageset'));
      await image.create(recursive: true);
      await File(
        p.join(image.path, 'Contents.json'),
      ).writeAsString('{"images":[]}');
      catalogs.add(catalog.path);
    }
    await expectLater(
      AssetCatalogCompiler().compile(catalogs, p.join(root.path, 'output')),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.message,
          'message',
          contains('identifier collision between "Image1623" and "Image8000"'),
        ),
      ),
    );
  });
  test(
    'reserves every SVG bitmap scale but ignores empty image slots',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'xcross-svg-variants-',
      );
      addTearDown(() => root.delete(recursive: true));
      final image = Directory(p.join(root.path, 'Example.imageset'))
        ..createSync();
      final file = File(p.join(image.path, 'Contents.json'));
      for (final second in ['override.png', 'other.svg']) {
        file.writeAsStringSync(
          jsonEncode({
            'images': [
              {'filename': 'symbol.svg', 'scale': '1x'},
              {'filename': second, 'scale': '2x'},
            ],
          }),
        );
        expect(
          () => AssetCatalogCompiler().validate(root.path),
          throwsA(
            isA<FlutterBuildError>().having(
              (error) => error.message,
              'message',
              contains('SVGs occupy all three'),
            ),
          ),
        );
      }
      file.writeAsStringSync(
        jsonEncode({
          'images': [
            {'scale': '1x'},
            {'scale': '2x', 'filename': ''},
            {'filename': 'symbol.svg'},
          ],
        }),
      );
      expect(() => AssetCatalogCompiler().validate(root.path), returnsNormally);
    },
  );
  test('rejects case-insensitive staging directory collisions', () async {
    final root = await Directory.systemTemp.createTemp('xcross-asset-case-');
    addTearDown(() => root.delete(recursive: true));
    final catalogs = <String>[];
    for (final (catalogName, imageName) in [('A', 'Icon'), ('B', 'icon')]) {
      final catalog = Directory(p.join(root.path, '$catalogName.xcassets'));
      final image = Directory(p.join(catalog.path, '$imageName.imageset'));
      await image.create(recursive: true);
      await File(
        p.join(image.path, 'Contents.json'),
      ).writeAsString('{"images":[]}');
      catalogs.add(catalog.path);
    }
    await expectLater(
      AssetCatalogCompiler().compile(catalogs, p.join(root.path, 'output')),
      throwsA(
        isA<FlutterBuildError>().having(
          (error) => error.message,
          'message',
          contains('collide on this filesystem'),
        ),
      ),
    );
  }, skip: !Platform.isWindows);
  test('rejects gamut variants with indistinguishable lookup keys', () async {
    final root = await Directory.systemTemp.createTemp('xcross-gamut-');
    addTearDown(() => root.delete(recursive: true));
    for (final kind in ['imageset', 'colorset']) {
      final asset = Directory(p.join(root.path, 'Example.$kind'))..createSync();
      final file = File(p.join(asset.path, 'Contents.json'));
      file.writeAsStringSync(
        jsonEncode({
          kind == 'imageset' ? 'images' : 'colors': [
            for (final gamut in ['sRGB', 'display-P3'])
              {
                'idiom': 'universal',
                'display-gamut': gamut,
                if (kind == 'imageset') 'filename': 'pixel.png',
                if (kind == 'colorset')
                  'color': {
                    'color-space': 'srgb',
                    'components': {
                      'red': '1',
                      'green': '0',
                      'blue': '0',
                      'alpha': '1',
                    },
                  },
              },
          ],
        }),
      );
      expect(
        () => AssetCatalogCompiler().validate(root.path),
        throwsA(
          isA<FlutterBuildError>().having(
            (error) => error.message,
            'message',
            contains('display-gamut'),
          ),
        ),
      );
      await asset.delete(recursive: true);
    }
  });
}

/// Independent bounds-checking reader verifies table sizes and object references.
List<(String, Map<String, Object>)> readNib(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  expect(ascii.decode(bytes.sublist(0, 10)), 'NIBArchive');
  final objectCount = data.getUint32(18, Endian.little);
  final keyCount = data.getUint32(26, Endian.little);
  final valueCount = data.getUint32(34, Endian.little);
  final classCount = data.getUint32(42, Endian.little);
  var cursor = data.getUint32(22, Endian.little);
  int variable() {
    var value = 0;
    var shift = 0;
    while (true) {
      final b = bytes[cursor++];
      value |= (b & 127) << shift;
      if (b & 128 != 0) return value;
      shift += 7;
      expect(shift, lessThan(64));
    }
  }

  final objects = [
    for (var i = 0; i < objectCount; i++) (variable(), variable(), variable()),
  ];
  expect(cursor, data.getUint32(30, Endian.little));
  final keys = <String>[];
  for (var i = 0; i < keyCount; i++) {
    final length = variable();
    keys.add(utf8.decode(bytes.sublist(cursor, cursor + length)));
    cursor += length;
  }
  expect(cursor, data.getUint32(38, Endian.little));
  final values = <(String, Object)>[];
  for (var i = 0; i < valueCount; i++) {
    final key = keys[variable()];
    final type = bytes[cursor++];
    final Object value;
    switch (type) {
      case 0:
        value = bytes[cursor++];
      case 1:
        value = data.getUint16(cursor, Endian.little);
        cursor += 2;
      case 2:
        value = data.getInt32(cursor, Endian.little);
        cursor += 4;
      case 4:
        value = false;
      case 5:
        value = true;
      case 7:
        value = data.getFloat64(cursor, Endian.little);
        cursor += 8;
      case 8:
        final length = variable();
        value = bytes.sublist(cursor, cursor + length);
        cursor += length;
      case 10:
        final ref = data.getUint32(cursor, Endian.little);
        cursor += 4;
        expect(ref, lessThan(objectCount));
        value = ref;
      default:
        throw StateError('Unknown NIB type $type');
    }
    values.add((key, value));
  }
  expect(cursor, data.getUint32(46, Endian.little));
  final classes = <String>[];
  for (var i = 0; i < classCount; i++) {
    final length = variable();
    expect(variable(), 0);
    classes.add(utf8.decode(bytes.sublist(cursor, cursor + length - 1)));
    cursor += length;
  }
  expect(cursor, bytes.length);
  return [
    for (final (type, start, count) in objects)
      (
        classes[type],
        {
          for (final value in values.sublist(start, start + count))
            value.$1: value.$2,
        },
      ),
  ];
}
