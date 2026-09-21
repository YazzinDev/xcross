import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/flutter/flutter.dart';

final class CoreDeviceLaunchProfile {
  const CoreDeviceLaunchProfile.native({this.arguments = const []})
    : hotReload = null,
      _flutterRuntime = false;

  const CoreDeviceLaunchProfile.flutter({
    required this.hotReload,
    this.arguments = const [],
  }) : _flutterRuntime = true;

  final List<String> arguments;
  final HotReloadConfig? hotReload;
  final bool _flutterRuntime;

  List<String> argumentsForLaunch({
    required bool isDap,
    bool ipv6VmService = false,
  }) => [
    if (_flutterRuntime && hotReload != null) ...[
      // Flutter's iOS embedder refuses to create a Debug engine on iOS 14+
      // unless the launch came from tooling. flutter_tools supplies this
      // switch through ios-deploy/Xcode; CoreDevice needs it explicitly.
      '--enable-dart-profiling',
      '--vm-service-host=${ipv6VmService ? '::0' : '0.0.0.0'}',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
    ],
    if (_flutterRuntime) ...['--enable-checked-mode', '--verify-entry-points'],
    ...arguments,
  ];
}
