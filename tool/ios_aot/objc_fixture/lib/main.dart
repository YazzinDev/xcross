import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:objective_c/objective_c.dart';

void main() => runApp(const ObjectiveCProbe());

class ObjectiveCProbe extends StatefulWidget {
  const ObjectiveCProbe({super.key});
  @override
  State<ObjectiveCProbe> createState() => _ObjectiveCProbeState();
}

class _ObjectiveCProbeState extends State<ObjectiveCProbe> {
  int runs = 1;
  @override
  Widget build(BuildContext context) {
    String report;
    var passed = false;
    try {
      final (text, number) = autoReleasePool(() {
        final string = 'Windows → iOS ✓'.toNSString().toDartString();
        final number = 338350.toNSNumber().longLongValue;
        return (string, number);
      });
      passed =
          kReleaseMode &&
          Platform.isIOS &&
          text == 'Windows → iOS ✓' &&
          number == 338350;
      report = 'release=$kReleaseMode\nNSString=$text\nNSNumber=$number';
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
                  'xcross release objective_c 9.6.0\n$report\nruns=$runs\nTap to recompute',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
