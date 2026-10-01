import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

int sumSquares(int limit) {
  var result = 0;
  for (var value = 1; value <= limit; value++) {
    result += value * value;
  }
  return result;
}

Future<void> main() async {
  // An opt-in delay makes the system-owned launch storyboard observable.
  const delay = int.fromEnvironment('PROBE_STARTUP_DELAY_MS');
  if (delay > 0) {
    // The default is zero, but device checks supply a compile-time override.
    // ignore: avoid_redundant_argument_values, use_named_constants
    await Future<void>.delayed(const Duration(milliseconds: delay));
  }
  runApp(const AotProbe());
}

class AotProbe extends StatefulWidget {
  const AotProbe({super.key});

  @override
  State<AotProbe> createState() => _AotProbeState();
}

class _AotProbeState extends State<AotProbe> {
  int runs = 1;

  @override
  Widget build(BuildContext context) {
    final result = sumSquares(100);
    const marker = String.fromEnvironment(
      'PROBE_MARKER',
      defaultValue: 'unset',
    );
    final passed = kReleaseMode && Platform.isIOS && result == 338350;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: passed ? const Color(0xff123b2a) : const Color(0xff5c2020),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: DefaultTextStyle(
              style: const TextStyle(color: Color(0xffffffff), fontSize: 22),
              textAlign: TextAlign.center,
              child: GestureDetector(
                onTap: () => setState(() => runs++),
                child: Text(
                  'xcross iOS AOT probe\n'
                  'release=$kReleaseMode\n'
                  'os=${Platform.operatingSystem}\n'
                  'sumSquares(100)=$result\n'
                  'marker=$marker\n'
                  'runs=$runs\nTap to recompute',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
