import 'dart:convert';
import 'dart:io';

/// Checks the actual packaged notice artifact after an xcross integration build.
void main(List<String> arguments) {
  if (arguments.length != 1) {
    throw ArgumentError('Expected the xcross-ios output directory');
  }
  final apps = Directory(arguments.single)
      .listSync()
      .whereType<Directory>()
      .where((directory) => directory.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) {
    throw StateError('Expected one .app, found ${apps.length}');
  }
  final artifact = File.fromUri(
    apps.single.uri.resolve(
      'Frameworks/App.framework/flutter_assets/NOTICES.Z',
    ),
  );
  final notices = utf8.decode(gzip.decode(artifact.readAsBytesSync()));
  final hasFlutterNotice = notices
      .split('\n${List.filled(80, '-').join()}\n')
      .any((entry) {
        final separator = entry.indexOf('\n\n');
        return separator > 0 &&
            entry.substring(0, separator).split('\n').contains('flutter') &&
            entry.substring(separator + 2).trim().isNotEmpty;
      });
  if (!hasFlutterNotice) {
    throw StateError('Missing Flutter package notice in ${artifact.path}');
  }
  stdout.writeln('Verified packaged Flutter notices: ${artifact.path}');
}
