import 'dart:io';
import 'package:xcross/src/flutter/build/internal/build_lock.dart';

Future<void> main(List<String> args) async {
  final counter = File(args[1]);
  for (var i = 0; i < 12; i++) {
    await withBuildLock(args[0], () async {
      final value = int.parse(await counter.readAsString());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await counter.writeAsString('${value + 1}');
    });
  }
}
