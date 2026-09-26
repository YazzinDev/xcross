import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';

/// Copies Flutter's generated compressed license notices into App.framework.
void copyFlutterNoticeArtifact({
  required String sourceFlutterAssetsDirectory,
  required String destinationFlutterAssetsDirectory,
}) {
  final source = File(p.join(sourceFlutterAssetsDirectory, 'NOTICES.Z'));
  if (!source.existsSync()) {
    throw FlutterBuildError(
      'Flutter iOS asset assembly did not produce $source',
    );
  }

  final destination = File(
    p.join(destinationFlutterAssetsDirectory, 'NOTICES.Z'),
  );
  source.copySync(destination.path);
}
