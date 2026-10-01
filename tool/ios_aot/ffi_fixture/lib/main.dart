import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xcross_c_ffi_probe/probe.dart';

void main() => runApp(const FfiProbe());

class FfiProbe extends StatefulWidget {
  const FfiProbe({super.key});
  @override
  State<FfiProbe> createState() => _FfiProbeState();
}

class _FfiProbeState extends State<FfiProbe> {
  int runs = 1;
  @override
  Widget build(BuildContext context) {
    String report;
    var passed = false;
    try {
      final callback = NativeCallable<Int64 Function(Int64)>.isolateLocal(
        (int value) => value * 3,
        exceptionalReturn: -1,
      );
      final int callbackResult;
      try {
        callbackResult = callCallback(42, callback.nativeFunction);
      } finally {
        callback.close();
      }
      final pairResult = sumPair(makePair(42, 0.5));
      final product = productBuild();
      final marker = recordedMarker('ffi-fixture-real-entrypoint');
      passed =
          kReleaseMode &&
          Platform.isIOS &&
          callbackResult == 126 &&
          pairResult == 42.5 &&
          product == 1;
      report =
          'release=$kReleaseMode\nC callback=$callbackResult\nstruct=$pairResult\nNDEBUG=$product\n$marker';
    } catch (error) {
      report = '$error';
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: passed ? const Color(0xff123b2a) : const Color(0xff5c2020),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: DefaultTextStyle(
              style: const TextStyle(color: Color(0xffffffff), fontSize: 21),
              textAlign: TextAlign.center,
              child: GestureDetector(
                onTap: () => setState(() => runs++),
                child: Text(
                  'xcross release C FFI\n$report\nruns=$runs\nTap to recompute',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
