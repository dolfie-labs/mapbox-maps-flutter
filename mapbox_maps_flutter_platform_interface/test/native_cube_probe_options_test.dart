import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface.dart';

void main() {
  test(
    'rejects coordinates outside the supported projection before transport',
    () {
      for (final latitude in [double.nan, double.infinity, 85.1, -85.1]) {
        expect(
          () => NativeCubeProbeOptions(latitude: latitude, longitude: 0),
          throwsArgumentError,
        );
      }
      for (final longitude in [double.nan, double.infinity, 181.0, -181.0]) {
        expect(
          () => NativeCubeProbeOptions(latitude: 0, longitude: longitude),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'rejects invalid metric geometry and accepts stationary repaint probes',
    () {
      for (final size in [0.0, -1.0, double.infinity]) {
        expect(
          () => NativeCubeProbeOptions(
            latitude: 0,
            longitude: 0,
            sizeMeters: size,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => NativeCubeProbeOptions(
          latitude: 0,
          longitude: 0,
          headingDegrees: double.nan,
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeCubeProbeOptions(
          latitude: 0,
          longitude: 0,
          rotationDegreesPerSecond: 0,
        ),
        returnsNormally,
      );
    },
  );
}
