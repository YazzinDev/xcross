import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/flutter/flutter.dart';

final class CoreDeviceLaunchProfile {
  const CoreDeviceLaunchProfile.native({this.arguments = const []})
    : hotReload = null,
      _flutterRuntime = false,
      attachDebugger = true;

  const CoreDeviceLaunchProfile.flutter({
    required this.hotReload,
    this.arguments = const [],
  }) : _flutterRuntime = true,
       attachDebugger = true;

  const CoreDeviceLaunchProfile.flutterRelease({this.arguments = const []})
    : hotReload = null,
      _flutterRuntime = false,
      attachDebugger = false;

  final List<String> arguments;
  final HotReloadConfig? hotReload;
  final bool attachDebugger;
  final bool _flutterRuntime;

  List<String> argumentsForLaunch({
    required bool isDap,
    bool ipv6VmService = false,
  }) => [
    if (_flutterRuntime && hotReload != null) ...[
      '--vm-service-host=${ipv6VmService ? '::0' : '0.0.0.0'}',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
    ],
    if (_flutterRuntime) ...['--enable-checked-mode', '--verify-entry-points'],
    ...arguments,
  ];
}
