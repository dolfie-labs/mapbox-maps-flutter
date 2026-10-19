/// Configuration for the experimental native custom-layer feasibility probe.
///
/// This renders one rotating cube, not a glTF model or a skeletal animation.
/// Coordinates are restricted to the Mercator projection supported by the probe.
final class NativeCubeProbeOptions {
  NativeCubeProbeOptions({
    required this.latitude,
    required this.longitude,
    this.altitudeMeters = 0,
    this.sizeMeters = 20,
    this.headingDegrees = 0,
    this.rotationDegreesPerSecond = 30,
    this.paused = false,
  }) {
    if (!latitude.isFinite || latitude.abs() > mercatorLatitudeLimit) {
      throw ArgumentError.value(latitude, 'latitude', 'Outside Mercator range');
    }
    if (!longitude.isFinite || longitude.abs() > 180) {
      throw ArgumentError.value(longitude, 'longitude', 'Outside WGS84 range');
    }
    for (final entry in {
      'altitudeMeters': altitudeMeters,
      'sizeMeters': sizeMeters,
      'headingDegrees': headingDegrees,
      'rotationDegreesPerSecond': rotationDegreesPerSecond,
    }.entries) {
      if (!entry.value.isFinite) {
        throw ArgumentError.value(entry.value, entry.key, 'Must be finite');
      }
    }
    if (sizeMeters <= 0) {
      throw ArgumentError.value(sizeMeters, 'sizeMeters', 'Must be positive');
    }
  }

  static const mercatorLatitudeLimit = 85.05112878;

  final double latitude;
  final double longitude;
  final double altitudeMeters;
  final double sizeMeters;
  final double headingDegrees;
  final double rotationDegreesPerSecond;
  final bool paused;
}

enum NativeCustomLayerProbeBackend { androidGLES, iosMetal }

/// Observations from the native probe, not a device benchmark or presentation
/// guarantee. A submitted draw increments [renderedFrames]; it does not prove
/// the frame reached the display.
final class NativeCustomLayerProbeDiagnostics {
  const NativeCustomLayerProbeDiagnostics({
    required this.backend,
    required this.attached,
    required this.paused,
    required this.styleLayerPresent,
    required this.initialized,
    required this.repaintEnabled,
    required this.renderedFrames,
    required this.lastErrorCode,
    this.incomingGlErrorCode,
  });

  final NativeCustomLayerProbeBackend backend;

  /// Whether a cube has been requested; this is not GPU readiness.
  final bool attached;
  final bool paused;
  final bool styleLayerPresent;
  final bool initialized;
  final bool repaintEnabled;
  final int renderedFrames;
  final String? lastErrorCode;

  /// Most recent GL error already pending when the renderer callback started.
  /// This inherited warning is separate from the probe's [lastErrorCode].
  /// It remains visible until explicit reattachment and is absent on iOS.
  final String? incomingGlErrorCode;

  /// A cube probe never advertises glTF or skeletal animation support.
  bool get supportsSkeletalAnimation => false;
}
