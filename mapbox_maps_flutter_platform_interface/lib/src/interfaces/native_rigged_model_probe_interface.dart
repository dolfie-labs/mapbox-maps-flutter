import '../public/native_rigged_model_probe.dart';

/// Optional capability; the original map platform interface is unchanged.
abstract interface class NativeRiggedModelProbeProvider {
  NativeRiggedModelProbePlatformInterface get nativeRiggedModelProbe;
}

abstract interface class NativeRiggedModelProbePlatformInterface {
  /// Accepts one CPU-decoded model. Poll diagnostics for GPU readiness.
  /// Replaces an existing cube or model on this map.
  Future<void> attachRiggedModel(NativeRiggedModelProbeOptions options);

  /// Controls the current cube or model on this map.
  Future<void> setPaused(bool paused);

  /// Removes the current cube or model, preserving the map itself.
  Future<void> detach();

  Future<NativeRiggedModelProbeDiagnostics> getDiagnostics();
}
