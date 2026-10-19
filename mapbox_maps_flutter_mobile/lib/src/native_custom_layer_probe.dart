part of 'package:mapbox_maps_flutter_mobile/mapbox_maps_flutter_mobile.dart';

/// Separate method channel for the P0 probe. Existing Pigeon schemas and
/// channels are intentionally unchanged.
class _NativeCustomLayerProbeChannel
    implements NativeCustomLayerProbePlatformInterface {
  _NativeCustomLayerProbeChannel({
    required int channelSuffix,
    required BinaryMessenger binaryMessenger,
  }) : _channel = MethodChannel(
         'dev.movey.mapbox.animated_entities.v1.$channelSuffix',
         const StandardMethodCodec(),
         binaryMessenger,
       );

  final MethodChannel _channel;
  bool _disposed = false;

  @override
  Future<void> attachCube(NativeCubeProbeOptions options) async {
    await _invoke('attachCube', {
      'latitude': options.latitude,
      'longitude': options.longitude,
      'altitudeMeters': options.altitudeMeters,
      'sizeMeters': options.sizeMeters,
      'headingDegrees': options.headingDegrees,
      'rotationDegreesPerSecond': options.rotationDegreesPerSecond,
      'paused': options.paused,
    });
  }

  @override
  Future<void> setPaused(bool paused) async {
    await _invoke('setPaused', {'paused': paused});
  }

  @override
  Future<void> detach() async {
    await _invoke('detach');
  }

  @override
  Future<NativeCustomLayerProbeDiagnostics> getDiagnostics() async {
    final result = await _invoke('getDiagnostics');
    if (result is! Map<Object?, Object?>) {
      throw const FormatException('Missing native probe diagnostics');
    }
    T requiredValue<T>(String key) {
      final value = result[key];
      if (value is! T) {
        throw FormatException('Invalid native probe diagnostic: $key');
      }
      return value;
    }

    if (requiredValue<int>('protocolVersion') != 1) {
      throw const FormatException('Unsupported native probe protocol');
    }
    if (requiredValue<bool>('supportsSkeletalAnimation')) {
      throw const FormatException(
        'Cube probe cannot advertise skeletal support',
      );
    }
    final backend = switch (requiredValue<String>('backend')) {
      'androidGLES' => NativeCustomLayerProbeBackend.androidGLES,
      'iosMetal' => NativeCustomLayerProbeBackend.iosMetal,
      _ => throw const FormatException('Unknown native probe backend'),
    };
    final frames = requiredValue<int>('renderedFrames');
    if (frames < 0) {
      throw const FormatException('Negative native probe frame count');
    }
    if (!result.containsKey('lastErrorCode') ||
        (result['lastErrorCode'] != null &&
            result['lastErrorCode'] is! String)) {
      throw const FormatException('Invalid native probe error code');
    }
    final incomingGlErrorCode = result['incomingGlErrorCode'];
    if (incomingGlErrorCode != null && incomingGlErrorCode is! String) {
      throw const FormatException(
        'Invalid incoming native probe GL error code',
      );
    }
    return NativeCustomLayerProbeDiagnostics(
      backend: backend,
      attached: requiredValue<bool>('attached'),
      paused: requiredValue<bool>('paused'),
      styleLayerPresent: requiredValue<bool>('styleLayerPresent'),
      initialized: requiredValue<bool>('initialized'),
      repaintEnabled: requiredValue<bool>('repaintEnabled'),
      renderedFrames: frames,
      lastErrorCode: result['lastErrorCode'] as String?,
      incomingGlErrorCode: incomingGlErrorCode as String?,
    );
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object> arguments = const {},
  ]) async {
    if (_disposed) {
      throw StateError('Native custom-layer probe map has been disposed');
    }
    return _channel.invokeMethod<Object?>(method, {
      'protocolVersion': 1,
      ...arguments,
    });
  }

  void dispose() {
    _disposed = true;
  }
}
