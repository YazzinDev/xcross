import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/resources/nib_archive.dart';
import 'package:xcross/src/flutter/build/resources/storyboard_schema.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xml/xml.dart';

/// Compiles UIKit view trees into genuine storyboardc/NIBArchive resources.
/// Parsing and validation finish before any output is published.
final class StoryboardCompiler {
  Map<String, Uint8List> compile(String xml, {required String source}) {
    try {
      final document = XmlDocument.parse(xml);
      validateInterfaceDocument(document, source);
      final root = document.rootElement;
      final output = <String, Uint8List>{};
      if (p.extension(source) == '.xib') {
        final objects = root.getElement('objects');
        if (objects == null) {
          unsupportedInterface(source, root, 'missing objects');
        }
        final scene = _ViewGraph(source, objects);
        final tops = scene.buildObjects();
        output[''] = encodeNib(_archive(tops, scene.connections));
        return output;
      }
      final scenes =
          root.getElement('scenes')?.findElements('scene').toList() ?? [];
      if (scenes.isEmpty) unsupportedInterface(source, root, 'missing scenes');
      final identifiers = <String, String>{};
      final entries = <String, String>{};
      for (final sceneElement in scenes) {
        final objects = sceneElement.getElement('objects');
        if (objects == null) {
          unsupportedInterface(source, sceneElement, 'missing objects');
        }
        final controllers = objects.findElements('viewController').toList();
        for (final object in objects.childElements) {
          if (!{'viewController', 'placeholder'}.contains(object.name.local)) {
            unsupportedInterface(source, object, 'storyboard scene object');
          }
        }
        if (controllers.length != 1) {
          unsupportedInterface(source, sceneElement, 'scene controller count');
        }
        final controller = controllers.single;
        final id = controller.getAttribute('id');
        if (id == null) unsupportedInterface(source, controller, 'missing id');
        if (root.getAttribute('launchScreen') == 'YES' &&
            controller.getAttribute('customClass') != null) {
          unsupportedInterface(
            source,
            controller,
            'custom launch-screen class',
          );
        }
        final graph = _ViewGraph(source, objects);
        final controllerObject = graph.buildController(controller);
        // The view NIB's owner is the controller created by the scene NIB.
        // Referencing its scene object here would instantiate a second one.
        graph.objects[id] = _proxy('IBFilesOwner');
        final viewElements = controller.findElements('view').toList();
        if (viewElements.length != 1 ||
            viewElements.single.getAttribute('key') != 'view') {
          unsupportedInterface(source, controller, 'controller root view');
        }
        final view = graph.buildView(viewElements.single);
        final guides =
            controller.getElement('layoutGuides')?.childElements ??
            <XmlElement>[];
        final guideObjects = guides.map(graph.buildGuide).toList();
        graph.subviews.putIfAbsent(view, () => []).addAll(guideObjects);
        graph.finish();
        final token = sha256
            .convert(utf8.encode(id))
            .toString()
            .substring(0, 16);
        final sceneName = 'Scene-$token';
        final viewName = 'View-$token';
        final identifier =
            controller.getAttribute('storyboardIdentifier') ?? sceneName;
        if (identifiers.containsKey(identifier)) {
          unsupportedInterface(
            source,
            controller,
            'duplicate storyboard identifier',
          );
        }
        identifiers[identifier] = sceneName;
        entries[id] = identifier;
        controllerObject.set('UINibName', viewName);
        if (controller.getAttribute('storyboardIdentifier') != null) {
          controllerObject.set('UIStoryboardIdentifier', identifier);
        }
        final owner = _proxy('IBFilesOwner');
        final storyboard = _proxy('UIStoryboardPlaceholder');
        output['$viewName.nib'] = encodeNib(
          _archive(
            [view],
            [_outlet(owner, view, 'view'), ...graph.connections],
          ),
        );
        output['$sceneName.nib'] = encodeNib(
          _archive(
            [controllerObject, owner, storyboard],
            [
              _outlet(owner, controllerObject, 'sceneViewController'),
              _outlet(controllerObject, storyboard, 'storyboard'),
            ],
          ),
        );
      }
      final initial = root.getAttribute('initialViewController');
      if (initial != null && !entries.containsKey(initial)) {
        unsupportedInterface(
          source,
          root,
          'unknown initial controller $initial',
        );
      }
      final builder = XmlBuilder()
        ..processing('xml', 'version="1.0" encoding="UTF-8"')
        ..doctype(
          'plist',
          publicId: '-//Apple//DTD PLIST 1.0//EN',
          systemId: 'http://www.apple.com/DTDs/PropertyList-1.0.dtd',
        );
      builder.element(
        'plist',
        attributes: {'version': '1.0'},
        nest: () {
          builder.element(
            'dict',
            nest: () {
              builder.element('key', nest: 'UIStoryboardVersion');
              builder.element('integer', nest: '1');
              builder.element(
                'key',
                nest: 'UIViewControllerIdentifiersToNibNames',
              );
              builder.element(
                'dict',
                nest: () {
                  for (final entry in identifiers.entries) {
                    builder.element('key', nest: entry.key);
                    builder.element('string', nest: entry.value);
                  }
                },
              );
              if (initial != null) {
                builder.element(
                  'key',
                  nest: 'UIStoryboardDesignatedEntryPointIdentifier',
                );
                builder.element('string', nest: entries[initial]);
              }
            },
          );
        },
      );
      output['Info.plist'] = Uint8List.fromList(
        utf8.encode(builder.buildDocument().toXmlString()),
      );
      return output;
    } on FlutterBuildError {
      rethrow;
    } on Object catch (error) {
      throw FlutterBuildError('Cannot compile storyboard/XIB $source: $error');
    }
  }

  Future<void> compileFile(String source, String destination) async {
    final files = compile(await File(source).readAsString(), source: source);
    if (files.containsKey('')) {
      await File(destination).parent.create(recursive: true);
      await File(destination).writeAsBytes(files['']!);
    } else {
      final directory = Directory(destination);
      if (directory.existsSync()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
      for (final entry in files.entries) {
        await File(p.join(destination, entry.key)).writeAsBytes(entry.value);
      }
    }
  }
}

NibObject _proxy(String name) =>
    NibObject('UIProxyObject', {'UIProxiedObjectIdentifier': name});
NibObject _outlet(NibObject source, NibObject destination, String property) =>
    NibObject('UIRuntimeOutletConnection', {
      'UISource': source,
      'UIDestination': destination,
      'UILabel': property,
    });
NibObject _archive(List<NibObject> objects, List<NibObject> connections) =>
    NibObject('NSObject', {
      'UINibTopLevelObjectsKey': objects,
      'UINibObjectsKey': objects,
      'UINibConnectionsKey': connections,
    });

final class _ViewGraph {
  _ViewGraph(this.source, this.element);
  final String source;
  final XmlElement element;
  final objects = <String, NibObject>{};
  final subviews = <NibObject, List<NibObject>>{};
  final pending = <(XmlElement, NibObject)>[];
  final connections = <NibObject>[];

  NibObject remember(XmlElement node, NibObject object) {
    final id = node.getAttribute('id');
    if (id == null) unsupportedInterface(source, node, 'missing id');
    objects[id] = object;
    return object;
  }

  NibObject custom(XmlElement node, String original) {
    final name = node.getAttribute('customClass');
    return NibObject(
      name == null ? original : 'UIClassSwapper',
      name == null
          ? {}
          : {'UIOriginalClassName': original, 'UIClassName': name},
    );
  }

  NibObject buildController(XmlElement node) {
    if (node.getElement('connections') != null) {
      unsupportedInterface(source, node, 'controller outlets');
    }
    return remember(node, custom(node, 'UIViewController'));
  }

  NibObject buildGuide(XmlElement node) {
    final type = node.getAttribute('type');
    if (type != 'top' && type != 'bottom') {
      unsupportedInterface(source, node, 'layout guide type $type');
    }
    return remember(
      node,
      NibObject('_UILayoutGuide', {
        'UIOpaque': true,
        'UIHidden': true,
        'UIAutoresizeSubviews': true,
        'UIViewDoesNotTranslateAutoresizingMaskIntoConstraints': true,
        '_UILayoutGuideIdentifier': type == 'top'
            ? '_UIViewControllerTop'
            : '_UIViewControllerBottom',
      }),
    );
  }

  List<NibObject> buildObjects() {
    final result = <NibObject>[];
    for (final node in element.childElements) {
      if (node.name.local == 'placeholder') {
        final kind = node.getAttribute('placeholderIdentifier');
        if (kind == null ||
            !{'IBFilesOwner', 'IBFirstResponder'}.contains(kind)) {
          unsupportedInterface(source, node, 'placeholder $kind');
        }
        result.add(remember(node, _proxy(kind)));
        pending.add((node, result.last));
      } else if ({'view', 'imageView'}.contains(node.name.local)) {
        result.add(buildView(node));
      } else {
        unsupportedInterface(source, node, 'XIB root');
      }
    }
    finish();
    return result;
  }

  NibObject buildView(XmlElement node) {
    final object = remember(
      node,
      custom(node, node.name.local == 'imageView' ? 'UIImageView' : 'UIView'),
    );
    object.set('UIAutoresizingMask', 0);
    object.set(
      'UIAutoresizeSubviews',
      boolean(node, 'autoresizesSubviews', true),
    );
    object.set('UIClipsToBounds', boolean(node, 'clipsSubviews', false));
    object.set('UIHidden', boolean(node, 'hidden', false));
    if (node.getAttribute('opaque') != null) {
      object.set('UIOpaque', boolean(node, 'opaque', true));
    }
    if (node.getAttribute('multipleTouchEnabled') != null) {
      object.set(
        'UIMultipleTouchEnabled',
        boolean(node, 'multipleTouchEnabled', false),
      );
    }
    if (node.getAttribute('userInteractionEnabled') != null) {
      object.set(
        'UIUserInteractionDisabled',
        !boolean(node, 'userInteractionEnabled', true),
      );
    }
    if (node.getAttribute('alpha') != null) {
      object.set('UIAlpha', number(node, 'alpha', 1));
    }
    if (node.getAttribute('tag') != null) {
      object.set('UITag', integer(node, 'tag'));
    }
    if (!boolean(node, 'translatesAutoresizingMaskIntoConstraints', true)) {
      object.set('UIViewDoesNotTranslateAutoresizingMaskIntoConstraints', true);
    }
    final mode = node.getAttribute('contentMode') ?? 'scaleToFill';
    final index = _contentModes.indexOf(mode);
    if (index < 0) unsupportedInterface(source, node, 'contentMode $mode');
    if (index != 0) object.set('UIContentMode', index);
    final image = node.getAttribute('image');
    if (image != null) {
      object.set(
        'UIImage',
        NibObject('UIImageNibPlaceholder', {'UIResourceName': image}),
      );
    }
    final children = <NibObject>[];
    subviews[object] = children;
    for (final child in node.childElements) {
      switch (child.name.local) {
        case 'subviews':
          children.addAll(child.childElements.map(buildView));
        case 'rect':
          if (child.getAttribute('key') != 'frame') {
            unsupportedInterface(source, child, 'rect key');
          }
          final x = number(child, 'x', 0);
          final y = number(child, 'y', 0);
          final w = number(child, 'width', 0);
          final h = number(child, 'height', 0);
          if (w < 0 || h < 0) {
            unsupportedInterface(source, child, 'negative frame size');
          }
          object.set('UICenter', NibBytes.geometry([x + w / 2, y + h / 2]));
          object.set('UIBounds', NibBytes.geometry([0, 0, w, h]));
        case 'autoresizingMask':
          if (child.getAttribute('key') != 'autoresizingMask') {
            unsupportedInterface(source, child, 'mask key');
          }
          const names = [
            'flexibleMinX',
            'widthSizable',
            'flexibleMaxX',
            'flexibleMinY',
            'heightSizable',
            'flexibleMaxY',
          ];
          var mask = 0;
          for (var i = 0; i < names.length; i++) {
            if (boolean(child, names[i], false)) mask |= 1 << i;
          }
          object.set('UIAutoresizingMask', mask);
        case 'color':
          if (child.getAttribute('key') != 'backgroundColor') {
            unsupportedInterface(source, child, 'color key');
          }
          final space = child.getAttribute('customColorSpace');
          final colorSpace = child.getAttribute('colorSpace');
          if (colorSpace != null &&
              !{
                'custom',
                'calibratedRGB',
                'calibratedWhite',
              }.contains(colorSpace)) {
            unsupportedInterface(source, child, 'color space $colorSpace');
          }
          if (space != null &&
              !{
                'sRGB',
                'calibratedWhite',
                'genericGamma22GrayColorSpace',
              }.contains(space)) {
            unsupportedInterface(source, child, 'color space $space');
          }
          final white = child.getAttribute('white');
          final red = number(child, white != null ? 'white' : 'red', 0);
          final green = white != null ? red : number(child, 'green', 0);
          final blue = white != null ? red : number(child, 'blue', 0);
          object.set(
            'UIBackgroundColor',
            NibObject('UIColor', {
              'UIColorComponentCount': 4,
              'UIColorSpace': 2,
              'UIRed': red,
              'UIGreen': green,
              'UIBlue': blue,
              'UIAlpha': number(child, 'alpha', 1),
              'NSRGB': NibBytes.text('$red $green $blue'),
            }),
          );
        case 'constraints':
        case 'connections':
          break; // Resolve after all sibling IDs have been registered.
        default:
          unsupportedInterface(source, child, 'view child');
      }
    }
    pending.add((node, object));
    return object;
  }

  void finish() {
    for (final entry in subviews.entries) {
      if (entry.value.isNotEmpty) entry.key.set('UISubviews', entry.value);
    }
    for (final (node, owner) in pending) {
      final constraints = <NibObject>[];
      for (final c
          in node.getElement('constraints')?.childElements ?? <XmlElement>[]) {
        final multiplier = c.getAttribute('multiplier');
        if (multiplier != null && !{'1', '1.0', '1:1'}.contains(multiplier)) {
          unsupportedInterface(source, c, 'constraint multiplier $multiplier');
        }
        if (c.getAttribute('relation') case final String relation
            when relation != 'equal') {
          unsupportedInterface(source, c, 'constraint relation $relation');
        }
        final first = resolve(c, 'firstItem', owner);
        final secondId = c.getAttribute('secondItem');
        final second = secondId == null
            ? null
            : resolve(c, 'secondItem', owner);
        for (final item in [first, if (second != null) second]) {
          if (!subviews.containsKey(item)) {
            unsupportedInterface(
              source,
              c,
              'constraint to a non-view or controller layout guide',
            );
          }
        }
        final firstAttribute =
            _layoutAttributes[c.getAttribute('firstAttribute')];
        final secondAttribute = secondId == null
            ? 0
            : _layoutAttributes[c.getAttribute('secondAttribute')];
        if (firstAttribute == null || secondAttribute == null) {
          unsupportedInterface(source, c, 'constraint attribute');
        }
        final constant = number(c, 'constant', 0);
        final values = <String, Object>{
          'NSFirstItem': first,
          'NSFirstAttribute': firstAttribute,
          'NSFirstAttributeV2': firstAttribute,
          'NSSecondAttribute': secondAttribute,
          'NSSecondAttributeV2': secondAttribute,
          'NSConstant': constant,
          'NSConstantV2': constant,
          'NSShouldBeArchived': true,
        };
        if (second != null) {
          values['NSSecondItem'] = second;
        }
        if (c.getAttribute('priority') != null) {
          values['NSPriority'] = integer(c, 'priority');
        }
        constraints.add(NibObject('NSLayoutConstraint', values));
      }
      if (constraints.isNotEmpty) {
        owner.set('UIViewAutolayoutConstraints', constraints);
      }
      for (final outlet
          in node.getElement('connections')?.childElements ?? <XmlElement>[]) {
        final property = outlet.getAttribute('property');
        if (property == null ||
            property.isEmpty ||
            outlet.getAttribute('destination') == null) {
          unsupportedInterface(source, outlet, 'outlet property');
        }
        connections.add(
          _outlet(owner, resolve(outlet, 'destination', owner), property),
        );
      }
    }
  }

  NibObject resolve(XmlElement node, String attribute, NibObject fallback) {
    final id = node.getAttribute(attribute);
    if (id == null) return fallback;
    final result = objects[id];
    if (result == null) {
      unsupportedInterface(source, node, 'unresolved $attribute=$id');
    }
    return result;
  }

  // The fallback mirrors Interface Builder's omitted-property defaults.
  // ignore: avoid_positional_boolean_parameters
  bool boolean(XmlElement node, String key, bool fallback) {
    final value = node.getAttribute(key);
    if (value == null) return fallback;
    if (value == 'YES') return true;
    if (value == 'NO') return false;
    unsupportedInterface(source, node, 'boolean $key=$value');
  }

  double number(XmlElement node, String key, double fallback) {
    final text = node.getAttribute(key);
    if (text == null) return fallback;
    final value = double.tryParse(text);
    if (value == null || !value.isFinite) {
      unsupportedInterface(source, node, 'number $key=$text');
    }
    return value;
  }

  int integer(XmlElement node, String key) {
    final value = int.tryParse(node.getAttribute(key) ?? '');
    if (value == null) unsupportedInterface(source, node, 'integer $key');
    if (value < -0x80000000 || value > 0x7fffffff) {
      unsupportedInterface(
        source,
        node,
        'integer $key outside signed 32-bit range',
      );
    }
    return value;
  }
}

const _contentModes = [
  'scaleToFill',
  'scaleAspectFit',
  'scaleAspectFill',
  'redraw',
  'center',
  'top',
  'bottom',
  'left',
  'right',
  'topLeft',
  'topRight',
  'bottomLeft',
  'bottomRight',
];
const _layoutAttributes = {
  'left': 1,
  'right': 2,
  'top': 3,
  'bottom': 4,
  'leading': 5,
  'trailing': 6,
  'width': 7,
  'height': 8,
  'centerX': 9,
  'centerY': 10,
  'baseline': 11,
};
