import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/required_plist_key.dart';
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/constants.dart';
import 'package:xml/xml.dart';

/// Plist / xcconfig text manipulation for the generated app bundle.
///
/// Pure string transforms (plus one filesystem probe for compiled
/// storyboards); no state, no I/O beyond that probe.
abstract final class InfoPlist {
  /// Overwrite `CFBundleIdentifier` (used when qualifying the App ID at
  /// device-sign time).
  static String setBundleIdentifier(String plistXml, String bundleId) =>
      _setPlistKey(plistXml, 'CFBundleIdentifier', bundleId);

  /// Set an arbitrary string key, inserting it when absent.
  static String setPlistString(String plistXml, String key, String value) =>
      _setPlistKey(plistXml, key, value);

  /// Read `CFBundleIdentifier`, or null when absent.
  static String? readBundleIdentifier(String plistXml) {
    final match = RegExp(
      r'<key>CFBundleIdentifier</key>\s*<string>([^<]*)</string>',
    ).firstMatch(plistXml);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Replace [from] with [to] inside `CFBundleURLSchemes` values only.
  ///
  /// Schemes are conventionally derived from the bundle id
  /// (`ShareMedia-<bundle id>`), so qualifying the App ID at sign time also
  /// has to qualify the scheme, or the extension's redirect back into the
  /// app resolves to a scheme nothing has registered.
  ///
  /// The rewrite is deliberately confined to the scheme arrays: replacing
  /// [from] across the whole plist would also rewrite unrelated keys that
  /// legitimately mention the original bundle id.
  static String rewriteUrlSchemes(
    String plistXml, {
    required String from,
    required String to,
  }) {
    if (from == to || from.isEmpty) return plistXml;

    final arrays = RegExp(
      r'(<key>\s*CFBundleURLSchemes\s*</key>\s*<array>)(.*?)(</array>)',
      dotAll: true,
    );
    return plistXml.replaceAllMapped(arrays, (match) {
      final body = match
          .group(2)!
          .replaceAllMapped(
            RegExp('<string>([^<]*)</string>'),
            (scheme) =>
                '<string>${scheme.group(1)!.replaceAll(from, to)}</string>',
          );
      return '${match.group(1)}$body${match.group(3)}';
    });
  }

  /// Keys Xcode would inject at build time, added only when the template
  /// doesn't already declare them, in this exact order.
  ///
  /// The `UIDeviceFamily`/`DT*` group matters on iOS 26+: without it the OS
  /// refuses to register the app with SpringBoard/LaunchServices (it installs
  /// but won't launch — FBSApplicationLibrary returns nil).
  static const _requiredKeys = <RequiredPlistKey>[
    RequiredPlistKey(key: 'LSRequiresIPhoneOS', value: '<true/>'),
    RequiredPlistKey(
      key: 'CFBundleSupportedPlatforms',
      value: '<array><string>iPhoneOS</string></array>',
    ),
    RequiredPlistKey(
      key: 'UIRequiredDeviceCapabilities',
      value: '<array><string>arm64</string></array>',
    ),
    RequiredPlistKey(
      key: 'UIDeviceFamily',
      value: '<array><integer>1</integer></array>',
    ),
    RequiredPlistKey(key: 'DTPlatformName', value: '<string>iphoneos</string>'),
    RequiredPlistKey(
      key: 'DTSDKName',
      value: '<string>${IosDeploymentConstants.sdkTriple}</string>',
    ),
    RequiredPlistKey(
      key: 'DTPlatformVersion',
      value: '<string>${IosDeploymentConstants.sdkVersion}</string>',
    ),
  ];

  /// Overwrite or insert all mandatory iOS bundle keys.
  ///
  /// Version strings (CFBundleShortVersionString / CFBundleVersion) are NOT
  /// forced here — they come solely from $(FLUTTER_BUILD_NAME) /
  /// $(FLUTTER_BUILD_NUMBER) substitution so that xcconfig and --build-name
  /// values are respected.
  static String applyIosRequiredKeys(
    String plistXml, {
    required String bundleId,
    required IosDeploymentTarget deploymentTarget,
  }) {
    var xml = _setPlistKey(
      plistXml,
      'CFBundleExecutable',
      PlistDefaults.executable,
    );
    xml = setBundleIdentifier(xml, bundleId);
    xml = _setPlistKey(xml, 'CFBundlePackageType', 'APPL');
    xml = _setPlistKey(
      xml,
      IosDeploymentConstants.minimumOsVersionKey,
      deploymentTarget.version,
    );
    for (final entry in _requiredKeys) {
      if (xml.contains(entry.key)) continue;
      xml = _insertBeforeEnd(
        xml,
        '\t<key>${entry.key}</key>\n\t${entry.value}\n',
      );
    }
    return xml;
  }

  /// Add the Debug-only local-network declarations Flutter's Xcode backend
  /// writes into the produced app bundle for the Dart VM Service.
  ///
  /// xcross packs debug/JIT bundles without Xcode, so this mirrors
  /// `xcode_backend.dart` rather than requiring every application template to
  /// carry development-only permission text in its source Info.plist.
  static String applyDebugVmServiceDiscovery(String plistXml) {
    const service = '_dartVmService._tcp';
    final document = XmlDocument.parse(plistXml);
    final root = document.rootElement.getElement('dict');
    if (root == null) {
      throw const FormatException('Info.plist has no root dict');
    }

    XmlElement? valueFor(String name) {
      final entries = root.childElements.toList();
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].name.local == 'key' && entries[i].innerText == name) {
          if (i + 1 >= entries.length || entries[i + 1].name.local == 'key') {
            throw FormatException('Info.plist key $name has no value');
          }
          return entries[i + 1];
        }
      }
      return null;
    }

    final currentServices = valueFor('NSBonjourServices');
    if (currentServices != null && currentServices.name.local != 'array') {
      throw const FormatException('NSBonjourServices must be an array');
    }
    final currentUsage = valueFor('NSLocalNetworkUsageDescription');
    if (currentUsage != null && currentUsage.name.local != 'string') {
      throw const FormatException(
        'NSLocalNetworkUsageDescription must be a string',
      );
    }
    if (currentServices?.childElements.any(
              (entry) =>
                  entry.name.local == 'string' && entry.innerText == service,
            ) ==
            true &&
        currentUsage != null) {
      return plistXml;
    }

    final services =
        currentServices ?? XmlElement(const XmlName.parts('array'));
    if (currentServices == null) {
      root.children.add(
        XmlElement(const XmlName.parts('key'), [], [
          XmlText('NSBonjourServices'),
        ]),
      );
      root.children.add(services);
    }
    if (!services.childElements.any(
      (entry) => entry.name.local == 'string' && entry.innerText == service,
    )) {
      services.children.add(
        XmlElement(const XmlName.parts('string'), [], [XmlText(service)]),
      );
    }
    if (currentUsage == null) {
      root.children.add(
        XmlElement(const XmlName.parts('key'), [], [
          XmlText('NSLocalNetworkUsageDescription'),
        ]),
      );
      root.children.add(
        XmlElement(const XmlName.parts('string'), [], [
          XmlText(
            'Allow Flutter tools on your computer to connect and debug '
            'your application. This prompt will not appear on release builds.',
          ),
        ]),
      );
    }
    return document.toXmlString();
  }

  /// Expand `$(KEY)` and `${KEY}` in [text] using [subs].
  static String expandVars(String text, Map<String, String> subs) {
    var result = text;
    for (final entry in subs.entries) {
      result = result
          .replaceAll('\$(${entry.key})', entry.value)
          .replaceAll('\${${entry.key}}', entry.value);
    }
    return result;
  }

  /// Evaluate assignments for one Xcode build context. Includes require a
  /// file location and are handled by [readXcconfigFiles].
  static Map<String, String> parseXcconfig(
    String text, {
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
  }) {
    final values = <String, String>{};
    final comments = _XcconfigComments();
    for (final line in text.split('\n')) {
      _applyXcconfigAssignment(
        comments.strip(line),
        values,
        configuration,
        sdk,
        arch,
      );
    }
    return _expandXcconfigValues(values);
  }

  /// Reads Xcode configuration files in precedence order.
  ///
  /// Xcode's Debug.xcconfig includes Generated.xcconfig and then overrides its
  /// settings. xcross does not run Xcode, so callers provide both files in
  /// that same order when expanding the application Info.plist.
  static Future<Map<String, String>> readXcconfigFiles(
    Iterable<String> paths, {
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
  }) async {
    final values = <String, String>{};
    final stack = <String>{};

    Future<void> read(String path, {required bool optional}) async {
      final file = File(path);
      if (!file.existsSync()) {
        if (optional) return;
        throw FormatException('Required xcconfig include not found: $path');
      }
      final resolved = p.normalize(file.absolute.path);
      if (!stack.add(resolved)) {
        throw FormatException('xcconfig include cycle at $resolved');
      }
      try {
        final comments = _XcconfigComments();
        for (final raw in await file.readAsLines()) {
          final line = comments.strip(raw).trim();
          final include = RegExp(
            r'^#include(\?)?\s+(?:"([^"]+)"|<([^>]+)>)\s*$',
          ).firstMatch(line);
          if (include != null) {
            await read(
              p.normalize(
                p.join(p.dirname(resolved), include[2] ?? include[3]),
              ),
              optional: include[1] == '?',
            );
          } else {
            _applyXcconfigAssignment(line, values, configuration, sdk, arch);
          }
        }
      } finally {
        stack.remove(resolved);
      }
    }

    for (final path in paths) {
      await read(path, optional: true);
    }
    return _expandXcconfigValues(values);
  }

  static void _applyXcconfigAssignment(
    String raw,
    Map<String, String> values,
    String configuration,
    String sdk,
    String arch,
  ) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) return;
    final assignment = RegExp(
      r'^([A-Za-z_][A-Za-z_0-9.]*)(\s*(?:\[[^\]]+\])*)\s*=\s*(.*)$',
    ).firstMatch(line);
    if (assignment == null) {
      throw FormatException('Unsupported xcconfig assignment: $line');
    }
    final key = assignment[1]!;
    final head = assignment[2]!;
    for (final match in RegExp(r'\[([^\]]+)\]').allMatches(head)) {
      final qualifier = match[1]!;
      final eq = qualifier.indexOf('=');
      final kind = eq < 0 ? 'config' : qualifier.substring(0, eq);
      final pattern = eq < 0 ? qualifier : qualifier.substring(eq + 1);
      final actual = switch (kind.toLowerCase()) {
        'config' => configuration,
        'sdk' => sdk,
        'arch' => arch,
        _ => throw FormatException(
          'Unsupported xcconfig qualifier: $qualifier',
        ),
      };
      final expression = RegExp(
        '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
        caseSensitive: false,
      );
      if (!expression.hasMatch(actual)) return;
    }
    final inherited = values[key] ?? '';
    values[key] = assignment[3]!
        .replaceAll(r'$(inherited)', inherited)
        .replaceAll(r'${inherited}', inherited);
  }

  static Map<String, String> _expandXcconfigValues(Map<String, String> values) {
    final expanded = <String, String>{};
    String resolve(String key, Set<String> stack) {
      if (expanded[key] case final String cached) return cached;
      if (!stack.add(key)) {
        throw FormatException('xcconfig variable cycle: $key');
      }
      final raw = values[key]!;
      final value = raw.replaceAllMapped(
        RegExp(r'\$\(([^)]+)\)|\$\{([^}]+)\}'),
        (match) {
          final reference = match[1] ?? match[2]!;
          return values.containsKey(reference)
              ? resolve(reference, stack)
              : match[0]!;
        },
      );
      stack.remove(key);
      return expanded[key] = value;
    }

    for (final key in values.keys) {
      resolve(key, <String>{});
    }
    return expanded;
  }

  /// Overwrite an existing `<key>K</key><string>…</string>` pair, or insert a
  /// new one before `</dict>` if the key is absent.
  static String _setPlistKey(String xml, String key, String value) {
    final pattern = RegExp(
      '<key>$key</key>\\s*<string>[^<]*</string>',
      dotAll: true,
    );
    final replacement = '<key>$key</key>\n\t<string>$value</string>';
    if (xml.contains('<key>$key</key>')) {
      // Every occurrence, not just the first: a template that declares the
      // same key twice (hand-edited plists do) would otherwise keep a stale
      // second copy, and CFBundle resolves duplicates to the *last* one, so
      // the value actually read back at runtime would be the one left behind.
      return xml.replaceAll(pattern, replacement);
    }
    return _insertBeforeEnd(xml, '\t$replacement\n');
  }

  /// Insert [fragment] before the closing `</dict>` of the root plist dict.
  /// Tries `</dict>\n</plist>` first (canonical), then falls back to the last
  /// bare `</dict>` to handle compact plist serialisations.
  static String _insertBeforeEnd(String xml, String fragment) {
    const sentinel = '</dict>\n</plist>';
    final idx = xml.lastIndexOf(sentinel);
    if (idx >= 0) {
      return xml.substring(0, idx) + fragment + xml.substring(idx);
    }
    const dictEnd = '</dict>';
    final dictIdx = xml.lastIndexOf(dictEnd);
    if (dictIdx >= 0) {
      return xml.substring(0, dictIdx) + fragment + xml.substring(dictIdx);
    }
    return xml + fragment;
  }

  /// Remove references to storyboards not present (compiled) in [bundleDir].
  /// xcross doesn't run `ibtool`, so missing storyboards would crash at launch.
  static String stripUnsatisfiableStoryboards(String xml, String bundleDir) {
    bool hasCompiled(String name) =>
        Directory(p.join(bundleDir, '$name.storyboardc')).existsSync();

    // Named local reused by Main and Scene patterns (identical predicate).
    String keepIfCompiled(Match m) =>
        hasCompiled(m.group(1)!) ? m.group(0)! : '';

    var result = xml.replaceAllMapped(_uiMainStoryboardPattern, keepIfCompiled);

    result = result.replaceAllMapped(_uiLaunchStoryboardPattern, (m) {
      if (hasCompiled(m.group(1)!)) {
        return m.group(0)!;
      }
      // Replace with UILaunchScreen programmatic launch screen if absent.
      // Reads the pre-launch-strip snapshot of `result` on purpose: hoisting
      // this check or chaining the replaceAllMapped calls changes which
      // snapshot is inspected and can emit a duplicate UILaunchScreen.
      if (!result.contains('UILaunchScreen')) {
        return '<key>UILaunchScreen</key>\n\t<dict/>';
      }
      return '';
    });

    result = result.replaceAllMapped(_uiSceneStoryboardPattern, keepIfCompiled);

    return result;
  }

  static String applySceneLifecycle(String xml) {
    const manifestKey = '<key>UIApplicationSceneManifest</key>';
    final manifestKeyStart = xml.indexOf(manifestKey);
    if (manifestKeyStart < 0) return _insertBeforeEnd(xml, _sceneManifest);

    final manifest = _containerAfterKey(
      xml,
      manifestKeyStart,
      manifestKey,
      'dict',
    );
    if (manifest == null) return xml;
    if (manifest.selfClosing) {
      return xml.replaceRange(
        manifestKeyStart,
        manifest.end,
        _sceneManifest.trimRight(),
      );
    }

    const roleKey = '<key>UIWindowSceneSessionRoleApplication</key>';
    final roleKeyStart = xml.indexOf(roleKey, manifest.start);
    if (roleKeyStart >= 0 && roleKeyStart < manifest.end) {
      final role = _containerAfterKey(xml, roleKeyStart, roleKey, 'array');
      if (role != null && role.end <= manifest.end) {
        return xml.replaceRange(
          roleKeyStart,
          role.end,
          _applicationSceneConfiguration.trim(),
        );
      }
    }

    const configurationsKey = '<key>UISceneConfigurations</key>';
    final configurationsKeyStart = xml.indexOf(
      configurationsKey,
      manifest.start,
    );
    if (configurationsKeyStart >= 0 && configurationsKeyStart < manifest.end) {
      final configurations = _containerAfterKey(
        xml,
        configurationsKeyStart,
        configurationsKey,
        'dict',
      );
      if (configurations != null && configurations.end <= manifest.end) {
        if (configurations.selfClosing) {
          return xml.replaceRange(
            configurations.start,
            configurations.end,
            '<dict>\n$_applicationSceneConfiguration\t\t</dict>',
          );
        }
        return xml.replaceRange(
          configurations.end - '</dict>'.length,
          configurations.end - '</dict>'.length,
          _applicationSceneConfiguration,
        );
      }
    }

    return xml.replaceRange(
      manifest.end - '</dict>'.length,
      manifest.end - '</dict>'.length,
      '\t\t<key>UISceneConfigurations</key>\n'
      '\t\t<dict>\n'
      '$_applicationSceneConfiguration'
      '\t\t</dict>\n',
    );
  }

  static ({int start, int end, bool selfClosing})? _containerAfterKey(
    String xml,
    int keyStart,
    String key,
    String tag,
  ) {
    final valueStart = keyStart + key.length;
    final value = RegExp('\\s*<$tag(/?)>').matchAsPrefix(xml, valueStart);
    if (value == null) return null;
    if (value.group(1) == '/') {
      return (start: value.start, end: value.end, selfClosing: true);
    }

    var depth = 0;
    for (final match in RegExp('</?$tag>').allMatches(xml, value.start)) {
      if (match.group(0) == '<$tag>') {
        depth++;
      } else if (--depth == 0) {
        return (start: value.start, end: match.end, selfClosing: false);
      }
    }
    return null;
  }

  static const _applicationSceneConfiguration =
      '\t\t\t<key>UIWindowSceneSessionRoleApplication</key>\n'
      '\t\t\t<array>\n'
      '\t\t\t\t<dict>\n'
      '\t\t\t\t\t<key>UISceneClassName</key>\n'
      '\t\t\t\t\t<string>UIWindowScene</string>\n'
      '\t\t\t\t\t<key>UISceneDelegateClassName</key>\n'
      '\t\t\t\t\t<string>SceneDelegate</string>\n'
      '\t\t\t\t\t<key>UISceneConfigurationName</key>\n'
      '\t\t\t\t\t<string>flutter</string>\n'
      '\t\t\t\t</dict>\n'
      '\t\t\t</array>\n';

  static const _sceneManifest =
      '\t<key>UIApplicationSceneManifest</key>\n'
      '\t<dict>\n'
      '\t\t<key>UIApplicationSupportsMultipleScenes</key>\n'
      '\t\t<false/>\n'
      '\t\t<key>UISceneConfigurations</key>\n'
      '\t\t<dict>\n'
      '$_applicationSceneConfiguration'
      '\t\t</dict>\n'
      '\t</dict>\n';

  /// Drop Swift module prefix from ObjC class names in the plist.
  /// The Runner shim registers `AppDelegate` / `SceneDelegate` without a module
  /// prefix, so `Runner.SceneDelegate` from the stock template would fail
  /// `NSClassFromString`.
  static String normalizeObjCClassNames(String xml) {
    return xml.replaceAllMapped(_objcClassNamePattern, (m) {
      final name = m.group(2)!;
      final dot = name.lastIndexOf('.');
      final unqualified = dot >= 0 ? name.substring(dot + 1) : name;
      return '${m.group(1)}$unqualified${m.group(3)}';
    });
  }

  static final _uiMainStoryboardPattern = RegExp(
    r'<key>UIMainStoryboardFile</key>\s*<string>([^<]*)</string>',
  );

  static final _uiLaunchStoryboardPattern = RegExp(
    r'<key>UILaunchStoryboardName</key>\s*<string>([^<]*)</string>',
  );

  static final _uiSceneStoryboardPattern = RegExp(
    r'<key>UISceneStoryboardFile</key>\s*<string>([^<]*)</string>',
  );

  static final _objcClassNamePattern = RegExp(
    r'(<key>(?:UISceneDelegateClassName|NSPrincipalClass)</key>\s*<string>)'
    '([^<]*)'
    '(</string>)',
  );

  /// Minimal plist used when the project has no `ios/Runner/Info.plist`.
  static const fallback =
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
      ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '$_sceneManifest'
      '\t<key>UILaunchScreen</key>\n'
      '\t<dict/>\n'
      '\t<key>UISupportedInterfaceOrientations</key>\n'
      '\t<array>\n'
      '\t\t<string>UIInterfaceOrientationPortrait</string>\n'
      '\t</array>\n'
      '</dict>\n'
      '</plist>\n';
}

/// Removes C-style comments without mistaking quoted values for comments.
/// The state belongs to one xcconfig file so a block may span several lines.
final class _XcconfigComments {
  bool _inBlock = false;

  String strip(String line) {
    final result = StringBuffer();
    var quoted = false;
    var escaped = false;
    for (var index = 0; index < line.length; index++) {
      final character = line[index];
      final next = index + 1 < line.length ? line[index + 1] : '';
      if (_inBlock) {
        if (character == '*' && next == '/') {
          _inBlock = false;
          index++;
        }
        continue;
      }
      if (!quoted && character == '/' && next == '*') {
        _inBlock = true;
        result.write(' ');
        index++;
        continue;
      }
      result.write(character);
      if (character == '"' && !escaped) quoted = !quoted;
      escaped = character == r'\' && !escaped;
    }
    return result.toString();
  }
}
