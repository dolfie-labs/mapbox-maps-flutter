import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface_internal.dart';
import 'package:meta/meta.dart';

/// Experimental one-model native GLB probe. Clip indices come from the asset;
/// this is not a multi-entity engine, GPS tracker or outfit system.
@experimental
final class NativeRiggedModelProbe {
  @internal
  NativeRiggedModelProbe(this._impl);

  final NativeRiggedModelProbePlatformInterface _impl;

  /// Completion means CPU decode accepted; poll [getDiagnostics] for readiness.
  Future<void> attachRiggedModel(NativeRiggedModelProbeOptions options) =>
      _impl.attachRiggedModel(options);

  /// Updates native placement and optional playback state without a GLB reload.
  Future<void> updateRiggedModel(NativeRiggedModelProbeUpdate update) =>
      _impl.updateRiggedModel(update);

  Future<void> setPaused(bool paused) => _impl.setPaused(paused);
  Future<void> detach() => _impl.detach();
  Future<NativeRiggedModelProbeDiagnostics> getDiagnostics() =>
      _impl.getDiagnostics();
}
