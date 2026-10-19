import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface.dart';

void main() {
  test(
    'keeps optional playback fields unset and accepts placement boundaries',
    () {
      final update = NativeRiggedModelProbeUpdate(
        latitude: NativeCubeProbeOptions.mercatorLatitudeLimit,
        longitude: -180,
        headingDegrees: -720,
      );
      expect(update.latitude, NativeCubeProbeOptions.mercatorLatitudeLimit);
      expect(update.longitude, -180);
      expect(update.headingDegrees, -720);
      expect(update.clipIndex, isNull);
      expect(update.playbackRate, isNull);
      expect(update.opacity, isNull);
      expect(update.opacityTransitionMilliseconds, isNull);
    },
  );

  test('hidden preload and native fade accept bounded opacity values', () {
    for (final opacity in [0.0, 0.5, 1.0]) {
      final update = NativeRiggedModelProbeUpdate(
        latitude: 0,
        longitude: 0,
        headingDegrees: 0,
        opacity: opacity,
        opacityTransitionMilliseconds: 220,
      );
      expect(update.opacity, opacity);
      expect(update.opacityTransitionMilliseconds, 220);
    }
  });

  test('rejects invalid native fades before transport', () {
    for (final opacity in [-0.1, 1.1, double.nan, double.infinity]) {
      expect(
        () => NativeRiggedModelProbeUpdate(
          latitude: 0,
          longitude: 0,
          headingDegrees: 0,
          opacity: opacity,
        ),
        throwsArgumentError,
      );
    }
    for (final duration in [-1, 1001]) {
      expect(
        () => NativeRiggedModelProbeUpdate(
          latitude: 0,
          longitude: 0,
          headingDegrees: 0,
          opacity: 1,
          opacityTransitionMilliseconds: duration,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => NativeRiggedModelProbeUpdate(
        latitude: 0,
        longitude: 0,
        headingDegrees: 0,
        opacityTransitionMilliseconds: 220,
      ),
      throwsArgumentError,
    );
  });

  test('rejects invalid placement before native transport', () {
    for (final latitude in [double.nan, double.infinity, 85.1, -85.1]) {
      expect(
        () => NativeRiggedModelProbeUpdate(
          latitude: latitude,
          longitude: 0,
          headingDegrees: 0,
        ),
        throwsArgumentError,
      );
    }
    for (final longitude in [double.nan, double.infinity, -181.0, 181.0]) {
      expect(
        () => NativeRiggedModelProbeUpdate(
          latitude: 0,
          longitude: longitude,
          headingDegrees: 0,
        ),
        throwsArgumentError,
      );
    }
    for (final heading in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(
        () => NativeRiggedModelProbeUpdate(
          latitude: 0,
          longitude: 0,
          headingDegrees: heading,
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'accepts optional rate boundaries and rejects invalid playback state',
    () {
      for (final rate in [0.0, 1.0, 4.0]) {
        final update = NativeRiggedModelProbeUpdate(
          latitude: 0,
          longitude: 0,
          headingDegrees: 0,
          clipIndex: 0,
          playbackRate: rate,
        );
        expect(update.clipIndex, 0);
        expect(update.playbackRate, rate);
      }
      for (final rate in [-0.1, 4.1, double.nan, double.infinity]) {
        expect(
          () => NativeRiggedModelProbeUpdate(
            latitude: 0,
            longitude: 0,
            headingDegrees: 0,
            playbackRate: rate,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => NativeRiggedModelProbeUpdate(
          latitude: 0,
          longitude: 0,
          headingDegrees: 0,
          clipIndex: -1,
        ),
        throwsArgumentError,
      );
    },
  );
}
