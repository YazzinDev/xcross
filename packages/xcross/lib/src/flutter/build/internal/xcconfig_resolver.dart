import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves one Xcode build configuration in its textual include order.
abstract final class XcconfigResolver {
  /// Flutter's generated settings are a fallback only when there is no
  /// authored Debug configuration. A Debug file that includes Generated must
  /// evaluate that include exactly once, at the point where it appears.
  static Future<Map<String, String>> readDebugConfiguration({
    required String debugPath,
    required String generatedPath,
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
  }) => readFiles(
    [if (File(debugPath).existsSync()) debugPath else generatedPath],
    configuration: configuration,
    sdk: sdk,
    arch: arch,
  );

  static Map<String, String> parseText(
    String text, {
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
  }) {
    final values = <String, String>{};
    final comments = _XcconfigComments();
    for (final line in text.split('\n')) {
      _applyAssignment(comments.strip(line), values, configuration, sdk, arch);
    }
    return _expandValues(values);
  }

  /// Process each root and its required or optional includes in text order.
  static Future<Map<String, String>> readFiles(
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
            _applyAssignment(line, values, configuration, sdk, arch);
          }
        }
      } finally {
        stack.remove(resolved);
      }
    }

    for (final path in paths) {
      await read(path, optional: true);
    }
    return _expandValues(values);
  }

  static void _applyAssignment(
    String raw,
    Map<String, String> values,
    String configuration,
    String sdk,
    String arch,
  ) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) return;
    // The selector may itself contain '='. Match the complete key and its
    // selectors before splitting off the assignment value.
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

  static Map<String, String> _expandValues(Map<String, String> values) {
    final expanded = <String, String>{};
    String resolve(String key, Set<String> stack) {
      if (expanded[key] case final String cached) return cached;
      if (!stack.add(key)) {
        throw FormatException('xcconfig variable cycle: $key');
      }
      final value = values[key]!.replaceAllMapped(
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
      // A trailing line comment starts after whitespace. Keep unquoted URL
      // values such as https://example.invalid intact.
      if (!quoted &&
          character == '/' &&
          next == '/' &&
          (index == 0 || line[index - 1].trim().isEmpty)) {
        break;
      }
      result.write(character);
      if (character == '"' && !escaped) quoted = !quoted;
      escaped = character == r'\' && !escaped;
    }
    return result.toString();
  }
}
