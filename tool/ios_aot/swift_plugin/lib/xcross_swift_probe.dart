// The fixture calls the registered channel directly.

/// Verifies that the engine invokes the generated Dart plugin registry.
final class DartProbePlugin {
  static bool registered = false;

  static void registerWith() => registered = true;
}
