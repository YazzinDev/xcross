import 'dart:io';

import 'package:xcross_ios_aot_probe/main.dart' as probe;

@pragma('vm:never-inline')
void symbolicationSentinel(int value) {
  if (value == 42) throw StateError('xcross intentional symbolication probe');
}

void main() {
  try {
    symbolicationSentinel(42);
  } catch (error, stack) {
    File('${Directory.systemTemp.path}/xcross-stack.txt')
        .writeAsStringSync('$stack');
  }
  probe.main();
}
