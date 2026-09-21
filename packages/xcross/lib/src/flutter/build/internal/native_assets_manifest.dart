import 'dart:convert';

/// Framework paths describe the iOS target, not the host that ran the hook.
/// Preserve asset identifiers and non-path lookup modes when normalizing
/// Windows separators, and preserve unchanged manifests byte-for-byte.
String normalizeIosNativeAssetsManifest(String source) {
  final manifest = jsonDecode(source) as Map<String, dynamic>;
  final targets = manifest['native-assets'] as Map<String, dynamic>;
  var changed = false;
  for (final target in targets.entries) {
    if (!target.key.startsWith('ios_')) continue;
    final assets = target.value as Map<String, dynamic>;
    for (final value in assets.values) {
      if (value is! List || value.length < 2) continue;
      if (value[0] != 'absolute' && value[0] != 'relative') continue;
      final path = value[1];
      if (path is! String || !path.contains(r'\')) continue;
      value[1] = path.replaceAll(r'\', '/');
      changed = true;
    }
  }
  return changed ? jsonEncode(manifest) : source;
}
