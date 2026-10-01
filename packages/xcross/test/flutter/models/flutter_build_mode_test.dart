import 'package:test/test.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';

void main() {
  test('default remains debug with its existing bundle location', () {
    expect(FlutterBuildMode.fromFlags(), FlutterBuildMode.debug);
    expect(const FlutterBuildOptions().mode.bundleDirectory, 'xcross-ios');
    expect(
      FlutterBuildMode.fromFlags(release: true).bundleDirectory,
      'xcross-ios-release',
    );
  });
  test('profile and conflicting mode flags fail explicitly', () {
    for (final flags in [
      () => FlutterBuildMode.fromFlags(profile: true),
      () => FlutterBuildMode.fromFlags(debug: true, release: true),
      () => FlutterBuildMode.fromFlags(release: true, profile: true),
    ]) {
      expect(flags, throwsA(isA<FlutterBuildError>()));
    }
  });
}
