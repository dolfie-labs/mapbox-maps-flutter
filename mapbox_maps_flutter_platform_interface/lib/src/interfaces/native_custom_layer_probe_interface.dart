import '../public/native_custom_layer_probe.dart';

/// Optional capability; deliberately separate from MapboxMapPlatformInterface
/// so existing platform implementations do not acquire new required members.
abstract interface class NativeCustomLayerProbeProvider {
  NativeCustomLayerProbePlatformInterface get nativeCustomLayerProbe;
}

abstract interface class NativeCustomLayerProbePlatformInterface {
  /// Accepts or replaces one cube. Completion is not a render-ready event.
  Future<void> attachCube(NativeCubeProbeOptions options);

  Future<void> setPaused(bool paused);

  /// Removes the probe, retaining the map and its original SDK resources.
  Future<void> detach();

  Future<NativeCustomLayerProbeDiagnostics> getDiagnostics();
}
