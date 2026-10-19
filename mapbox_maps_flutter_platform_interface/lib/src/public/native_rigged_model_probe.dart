import 'dart:typed_data';

import 'native_custom_layer_probe.dart';

/// One embedded rigged GLB for the experimental native model probe.
///
/// The bytes are copied into an unmodifiable view. Header validation happens
/// here; supported glTF structure and clip selection are validated natively.
final class NativeRiggedModelProbeOptions {
  NativeRiggedModelProbeOptions({
    required Uint8List glbBytes,
    required this.latitude,
    required this.longitude,
    this.altitudeMeters = 0,
    this.heightMeters = 20,
    this.headingDegrees = 0,
    this.clipIndex = 0,
    this.playbackRate = 1,
    this.paused = false,
    this.opacity = 1,
  }) : glbBytes = _copyGlb(glbBytes) {
    if (!latitude.isFinite ||
        latitude.abs() > NativeCubeProbeOptions.mercatorLatitudeLimit) {
      throw ArgumentError.value(latitude, 'latitude', 'Outside Mercator range');
    }
    if (!longitude.isFinite || longitude.abs() > 180) {
      throw ArgumentError.value(longitude, 'longitude', 'Outside WGS84 range');
    }
    for (final entry in {
      'altitudeMeters': altitudeMeters,
      'heightMeters': heightMeters,
      'headingDegrees': headingDegrees,
      'playbackRate': playbackRate,
    }.entries) {
      if (!entry.value.isFinite) {
        throw ArgumentError.value(entry.value, entry.key, 'Must be finite');
      }
    }
    if (heightMeters <= 0) {
      throw ArgumentError.value(
        heightMeters,
        'heightMeters',
        'Must be positive',
      );
    }
    if (clipIndex < 0) {
      throw ArgumentError.value(clipIndex, 'clipIndex', 'Must be nonnegative');
    }
    if (playbackRate < 0 || playbackRate > 4) {
      throw ArgumentError.value(playbackRate, 'playbackRate', 'Outside [0, 4]');
    }
    _validateOpacity(opacity);
  }

  static const maxGlbBytes = 2 * 1024 * 1024;

  static Uint8List _copyGlb(Uint8List bytes) {
    if (bytes.length > maxGlbBytes) {
      throw ArgumentError.value(bytes.length, 'glbBytes', 'Exceeds 2 MiB');
    }
    if (bytes.length < 12) {
      throw ArgumentError('glbBytes must contain a GLB 2 header');
    }
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(0, Endian.little) != 0x46546c67 ||
        header.getUint32(4, Endian.little) != 2 ||
        header.getUint32(8, Endian.little) != bytes.length) {
      throw ArgumentError('glbBytes must have a valid GLB 2 header and length');
    }
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  final Uint8List glbBytes;
  final double latitude;
  final double longitude;
  final double altitudeMeters;
  final double heightMeters;
  final double headingDegrees;
  final int clipIndex;
  final double playbackRate;
  final bool paused;

  /// Zero prepares GPU resources without drawing or writing depth.
  final double opacity;
}

/// Updates one accepted model without decoding its GLB or replacing GPU meshes.
///
/// Omitted clip and playback rate preserve the current selection. The native
/// clock resets only when [clipIndex] changes to a different clip.
final class NativeRiggedModelProbeUpdate {
  NativeRiggedModelProbeUpdate({
    required this.latitude,
    required this.longitude,
    required this.headingDegrees,
    this.clipIndex,
    this.playbackRate,
    this.opacity,
    this.opacityTransitionMilliseconds,
  }) {
    if (!latitude.isFinite ||
        latitude.abs() > NativeCubeProbeOptions.mercatorLatitudeLimit) {
      throw ArgumentError.value(latitude, 'latitude', 'Outside Mercator range');
    }
    if (!longitude.isFinite || longitude.abs() > 180) {
      throw ArgumentError.value(longitude, 'longitude', 'Outside WGS84 range');
    }
    if (!headingDegrees.isFinite) {
      throw ArgumentError.value(
        headingDegrees,
        'headingDegrees',
        'Must be finite',
      );
    }
    final clip = clipIndex;
    if (clip != null && clip < 0) {
      throw ArgumentError.value(clip, 'clipIndex', 'Must be nonnegative');
    }
    final rate = playbackRate;
    if (rate != null && (!rate.isFinite || rate < 0 || rate > 4)) {
      throw ArgumentError.value(rate, 'playbackRate', 'Outside [0, 4]');
    }
    final alpha = opacity;
    if (alpha != null) _validateOpacity(alpha);
    final duration = opacityTransitionMilliseconds;
    if (duration != null &&
        (alpha == null || duration < 0 || duration > 1000)) {
      throw ArgumentError.value(
        duration,
        'opacityTransitionMilliseconds',
        'Requires opacity and a duration in [0, 1000]',
      );
    }
  }

  final double latitude;
  final double longitude;
  final double headingDegrees;
  final int? clipIndex;
  final double? playbackRate;
  final double? opacity;

  /// A native-clock transition. Omission means an immediate opacity change.
  final int? opacityTransitionMilliseconds;
}

void _validateOpacity(double opacity) {
  if (!opacity.isFinite || opacity < 0 || opacity > 1) {
    throw ArgumentError.value(opacity, 'opacity', 'Outside [0, 1]');
  }
}

/// Native observations for one rigged model, separate from the cube probe.
/// Draw submission and GPU readiness do not establish visual correctness.
final class NativeRiggedModelProbeDiagnostics {
  const NativeRiggedModelProbeDiagnostics({
    required this.backend,
    required this.requested,
    required this.ready,
    required this.paused,
    required this.repaintEnabled,
    required this.renderedFrames,
    required this.poseRevision,
    required this.animationTimeSeconds,
    required this.vertexCount,
    required this.jointCount,
    required this.clipCount,
    required this.clipIndex,
    required this.lastErrorCode,
    this.incomingGlErrorCode,
    this.opacity,
    this.targetOpacity,
    this.isOpacityAnimating,
  });

  int get protocolVersion => 1;
  bool get supportsSkeletalAnimation => true;
  final NativeCustomLayerProbeBackend backend;
  final bool requested;

  /// True only after the native renderer has prepared GPU resources.
  final bool ready;
  final bool paused;
  final bool repaintEnabled;
  final int renderedFrames;
  final int poseRevision;
  final double animationTimeSeconds;
  final int vertexCount;
  final int jointCount;
  final int clipCount;
  final int clipIndex;
  final String? lastErrorCode;
  final String? incomingGlErrorCode;

  /// Optional for hosts predating hidden GPU preparation and opacity fades.
  final double? opacity;
  final double? targetOpacity;
  final bool? isOpacityAnimating;
}
