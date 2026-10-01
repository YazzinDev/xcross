import 'dart:developer';
import 'dart:io';

import 'package:xcross_ios_aot_probe/main.dart' as probe;

void main() {
  probe.main();
  Future<void>.delayed(const Duration(seconds: 2), () async {
    final info = await Service.getInfo();
    await File('${Directory.systemTemp.path}/xcross-debug-service.txt')
        .writeAsString(
          'uri=${info.serverUri}\nargs=${Platform.executableArguments}',
        );
  });
}
