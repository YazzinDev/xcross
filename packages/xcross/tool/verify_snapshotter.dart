import 'ios_aot/snapshotter_context.dart';
import 'ios_aot/snapshotter_probe.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Usage: verify_snapshotter.dart <bundle-root>');
  }
  await verifySnapshotterPackage(
    SnapshotterContext(findSnapshotterRepository()),
    arguments.single,
  );
}
