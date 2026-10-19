import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface_internal.dart';
import 'package:meta/meta.dart';

/// Experimental P0 native-rendering probe. This API renders a cube only.
///
/// Use a sized map with a loaded Mercator style. Inspect diagnostics and verify
/// the actual device output before treating the custom-layer gate as passed.
@experimental
final class NativeCustomLayerProbe {
  @internal
  NativeCustomLayerProbe(this._impl);

  final NativeCustomLayerProbePlatformInterface _impl;

  Future<void> attachCube(NativeCubeProbeOptions options) =>
      _impl.attachCube(options);

  Future<void> setPaused(bool paused) => _impl.setPaused(paused);

  Future<void> detach() => _impl.detach();

  Future<NativeCustomLayerProbeDiagnostics> getDiagnostics() =>
      _impl.getDiagnostics();
}
