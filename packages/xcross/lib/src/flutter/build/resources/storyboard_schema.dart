import 'package:xcross/src/flutter/errors.dart';
import 'package:xml/xml.dart';

/// Accepted XML is intentionally closed: new Interface Builder semantics must
/// be implemented before they may silently enter a shipping bundle.
void validateInterfaceDocument(XmlDocument document, String source) {
  for (final element in document.descendants.whereType<XmlElement>()) {
    if (element.name.prefix != null ||
        element.attributes.any((attribute) => attribute.name.prefix != null)) {
      unsupportedInterface(source, element, 'XML namespace');
    }
    final allowed = _attributes[element.name.local];
    if (allowed == null) unsupportedInterface(source, element, 'element');
    for (final attribute in element.attributes) {
      if (!allowed.contains(attribute.name.local)) {
        unsupportedInterface(source, element, 'attribute ${attribute.name}');
      }
    }
    final parents = _parents[element.name.local];
    if (parents != null &&
        !parents.contains(element.parentElement?.name.local)) {
      unsupportedInterface(
        source,
        element,
        'parent ${element.parentElement?.name}',
      );
    }
  }
  final root = document.rootElement;
  if (root.name.local != 'document' ||
      root.getAttribute('targetRuntime') != 'iOS.CocoaTouch') {
    unsupportedInterface(
      source,
      root,
      'target runtime (requires iOS.CocoaTouch)',
    );
  }
  final ids = <String>{};
  final storyboard = source.endsWith('.storyboard');
  if ((storyboard && root.getElement('objects') != null) ||
      (!storyboard && root.getElement('scenes') != null) ||
      root.findElements('scenes').length > 1 ||
      root.findElements('objects').length > 1) {
    unsupportedInterface(source, root, 'document structure');
  }
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (root.getAttribute('launchScreen') == 'YES' &&
        element.getAttribute('customClass') != null &&
        element.name.local != 'placeholder') {
      unsupportedInterface(source, element, 'custom launch-screen class');
    }
    if (element.name.local == 'placeholder' &&
        element.parentElement?.parentElement?.name.local == 'scene' &&
        (element.getAttribute('placeholderIdentifier') != 'IBFirstResponder' ||
            element.childElements.isNotEmpty)) {
      unsupportedInterface(source, element, 'storyboard placeholder');
    }
    if (element.name.local == 'document') {
      unsupportedInterface(source, element, 'nested document');
    }
    // Reject duplicate singular collections instead of dropping their content.
    for (final name in const [
      'subviews',
      'constraints',
      'connections',
      'layoutGuides',
      'autoresizingMask',
      'rect',
      'color',
      'scenes',
      'objects',
    ]) {
      if (element.findElements(name).length > 1) {
        unsupportedInterface(source, element, 'duplicate $name');
      }
    }
    final id = element.getAttribute('id');
    if (id != null && !ids.add(id)) {
      unsupportedInterface(source, element, 'duplicate id $id');
    }
  }
}

Never unsupportedInterface(String source, XmlElement element, String detail) =>
    throw FlutterBuildError(
      'Unsupported storyboard/XIB $detail in $source: '
      '<${element.name.local}> id=${element.getAttribute('id') ?? "-"}. '
      'xcross cannot compile this property yet; no layout was discarded.',
    );

const _identity = {'id', 'userLabel'};
const _viewAttributes = {
  ..._identity,
  'key',
  'contentMode',
  'customClass',
  'clipsSubviews',
  'opaque',
  'multipleTouchEnabled',
  'userInteractionEnabled',
  'hidden',
  'alpha',
  'tag',
  'translatesAutoresizingMaskIntoConstraints',
  'autoresizesSubviews',
};
const _attributes = <String, Set<String>>{
  'document': {
    'type',
    'version',
    'toolsVersion',
    'systemVersion',
    'targetRuntime',
    'propertyAccessControl',
    'useAutolayout',
    'useTraitCollections',
    'launchScreen',
    'colorMatched',
    'initialViewController',
  },
  'dependencies': {},
  'deployment': {'identifier', 'version'},
  'plugIn': {'identifier', 'version'},
  'capability': {'name', 'minToolsVersion'},
  'device': {'id', 'orientation', 'appearance'},
  'adaptation': {'id'},
  'scenes': {},
  'scene': {'sceneID'},
  'objects': {},
  'resources': {},
  'viewController': {
    ..._identity,
    'customClass',
    'sceneMemberID',
    'storyboardIdentifier',
  },
  'placeholder': {
    ..._identity,
    'placeholderIdentifier',
    'sceneMemberID',
    'customClass',
  },
  'view': _viewAttributes,
  'imageView': {..._viewAttributes, 'image'},
  'subviews': {},
  'layoutGuides': {},
  'constraints': {},
  'connections': {},
  'outlet': {..._identity, 'property', 'destination'},
  'viewControllerLayoutGuide': {..._identity, 'type'},
  'rect': {'key', 'x', 'y', 'width', 'height'},
  'point': {'key', 'x', 'y'},
  'autoresizingMask': {
    'key',
    'widthSizable',
    'heightSizable',
    'flexibleMinX',
    'flexibleMaxX',
    'flexibleMinY',
    'flexibleMaxY',
  },
  'color': {
    'key',
    'red',
    'green',
    'blue',
    'white',
    'alpha',
    'colorSpace',
    'customColorSpace',
  },
  'constraint': {
    ..._identity,
    'firstItem',
    'firstAttribute',
    'secondItem',
    'secondAttribute',
    'constant',
    'priority',
    'multiplier',
    'relation',
  },
  'image': {'name', 'width', 'height'},
};
const _parents = <String, Set<String>>{
  'dependencies': {'document'},
  'deployment': {'dependencies'},
  'plugIn': {'dependencies'},
  'capability': {'dependencies'},
  'device': {'document'},
  'adaptation': {'device'},
  'scenes': {'document'},
  'scene': {'scenes'},
  'objects': {'scene', 'document'},
  'resources': {'document'},
  'viewController': {'objects'},
  'placeholder': {'objects'},
  'view': {'viewController', 'subviews', 'objects'},
  'imageView': {'subviews', 'objects'},
  'subviews': {'view', 'imageView'},
  'layoutGuides': {'viewController'},
  'viewControllerLayoutGuide': {'layoutGuides'},
  'constraints': {'view', 'imageView'},
  'constraint': {'constraints'},
  'autoresizingMask': {'view', 'imageView'},
  'rect': {'view', 'imageView'},
  'color': {'view', 'imageView'},
  'point': {'scene'},
  'image': {'resources'},
  'connections': {'placeholder', 'view', 'imageView', 'viewController'},
  'outlet': {'connections'},
};
