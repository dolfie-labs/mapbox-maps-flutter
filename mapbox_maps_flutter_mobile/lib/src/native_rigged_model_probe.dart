part of 'package:mapbox_maps_flutter_mobile/mapbox_maps_flutter_mobile.dart';

/// Shares the map-scoped probe channel, pause/detach and disposal lifetime.
class _NativeRiggedModelProbeChannel
    implements NativeRiggedModelProbePlatformInterface {
  _NativeRiggedModelProbeChannel(this._channel);

  final _NativeCustomLayerProbeChannel _channel;

  @override
  Future<void> attachRiggedModel(NativeRiggedModelProbeOptions options) async {
    await _channel._invoke('attachRiggedModel', {
      'glbBytes': options.glbBytes,
      'latitude': options.latitude,
      'longitude': options.longitude,
      'altitudeMeters': options.altitudeMeters,
      'heightMeters': options.heightMeters,
      'headingDegrees': options.headingDegrees,
      'clipIndex': options.clipIndex,
      'playbackRate': options.playbackRate,
      'paused': options.paused,
    });
  }

  @override
  Future<void> setPaused(bool paused) => _channel.setPaused(paused);

  @override
  Future<void> detach() => _channel.detach();

  @override
  Future<NativeRiggedModelProbeDiagnostics> getDiagnostics() async {
    final result = await _channel._invoke('getRiggedModelDiagnostics');
    if (result is! Map<Object?, Object?>) {
      throw const FormatException('Missing native rigged model diagnostics');
    }
    T requiredValue<T>(String key) {
      final value = result[key];
      if (value is! T) {
        throw FormatException('Invalid rigged model diagnostic: $key');
      }
      return value;
    }

    int count(String key) {
      final value = requiredValue<int>(key);
      if (value < 0) {
        throw FormatException('Negative rigged model diagnostic: $key');
      }
      return value;
    }

    if (requiredValue<int>('protocolVersion') != 1) {
      throw const FormatException('Unsupported native rigged model protocol');
    }
    final backend = switch (requiredValue<String>('backend')) {
      'androidGLES' => NativeCustomLayerProbeBackend.androidGLES,
      'iosMetal' => NativeCustomLayerProbeBackend.iosMetal,
      _ => throw const FormatException('Unknown native rigged model backend'),
    };
    final animationTime = requiredValue<num>('animationTimeSeconds').toDouble();
    if (!animationTime.isFinite || animationTime < 0) {
      throw const FormatException('Invalid native animation time');
    }
    if (!result.containsKey('lastErrorCode') ||
        (result['lastErrorCode'] != null &&
            result['lastErrorCode'] is! String)) {
      throw const FormatException('Invalid native rigged model error code');
    }
    final incoming = result['incomingGlErrorCode'];
    if (incoming != null && incoming is! String) {
      throw const FormatException(
        'Invalid incoming rigged model GL error code',
      );
    }
    return NativeRiggedModelProbeDiagnostics(
      backend: backend,
      requested: requiredValue<bool>('requested'),
      ready: requiredValue<bool>('ready'),
      paused: requiredValue<bool>('paused'),
      repaintEnabled: requiredValue<bool>('repaintEnabled'),
      renderedFrames: count('renderedFrames'),
      poseRevision: count('poseRevision'),
      animationTimeSeconds: animationTime,
      vertexCount: count('vertexCount'),
      jointCount: count('jointCount'),
      clipCount: count('clipCount'),
      clipIndex: count('clipIndex'),
      lastErrorCode: result['lastErrorCode'] as String?,
      incomingGlErrorCode: incoming as String?,
    );
  }
}
