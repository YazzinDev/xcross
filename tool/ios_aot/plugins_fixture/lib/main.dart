import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xcross_swift_probe/xcross_swift_probe.dart';

void main() => runApp(const Probe());

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  int runs = 0;
  bool ok = false;
  String details = 'Waiting for native channels';
  @override
  void initState() {
    super.initState();
    recompute();
  }

  Future<void> recompute() async {
    try {
      final swift = await const MethodChannel('xcross/swift-probe')
          .invokeMapMethod<String, Object?>('probe')
          .timeout(const Duration(seconds: 10));
      final objc = await const MethodChannel('xcross/objc-probe')
          .invokeMapMethod<String, Object?>('probe')
          .timeout(const Duration(seconds: 10));
      setState(() {
        runs++;
        ok =
            kReleaseMode &&
            DartProbePlugin.registered &&
            Platform.isIOS &&
            swift?['sum'] == 338350 &&
            swift?['resource'] == 'transitive-resource-ok' &&
            swift?['release'] == true &&
            objc?['answer'] == 42 &&
            objc?['binary'] == 2026 &&
            objc?['release'] == true;
        details =
            'Dart registered=${DartProbePlugin.registered}\nSwift sum=${swift?['sum']} release=${swift?['release']}\n${swift?['resource']}\nObjC answer=${objc?['answer']} binary=${objc?['binary']} release=${objc?['release']}';
      });
    } catch (error) {
      setState(() {
        ok = false;
        details = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: GestureDetector(
      onTap: recompute,
      child: ColoredBox(
        color: ok ? const Color(0xff123b2b) : const Color(0xff6b2020),
        child: Center(
          child: Text(
            'xcross SwiftPM release\nrelease=$kReleaseMode\n$details\nruns=$runs\nTap to recompute',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 21, color: Color(0xffffffff)),
          ),
        ),
      ),
    ),
  );
}
