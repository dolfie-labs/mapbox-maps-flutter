import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface.dart';

// Header-only input: the native loader, not these options, validates chunks.
Uint8List _header([int length = 20]) {
  final bytes = Uint8List(length);
  final header = ByteData.sublistView(bytes);
  header.setUint32(0, 0x46546c67, Endian.little);
  header.setUint32(4, 2, Endian.little);
  header.setUint32(8, length, Endian.little);
  return bytes;
}

void main() {
  test('copies GLB bytes and prevents mutation through the public view', () {
    final input = _header();
    final options = NativeRiggedModelProbeOptions(
      glbBytes: input,
      latitude: 10,
      longitude: 106,
    );
    input[12] = 99;
    expect(options.glbBytes[12], 0);
    expect(() => options.glbBytes[12] = 1, throwsUnsupportedError);
    expect(
      () => options.glbBytes.buffer.asUint8List()[12] = 1,
      throwsUnsupportedError,
    );
    expect(options.clipIndex, 0);
    expect(options.playbackRate, 1);
  });

  test(
    'rejects truncation, invalid magic/version and mismatched GLB length',
    () {
      final badMagic = _header()..[0] = 0;
      final badVersion = _header()..[4] = 1;
      final badLength = _header()..[8] = 24;
      for (final bytes in [Uint8List(11), badMagic, badVersion, badLength]) {
        expect(
          () => NativeRiggedModelProbeOptions(
            glbBytes: bytes,
            latitude: 0,
            longitude: 0,
          ),
          throwsArgumentError,
        );
      }
    },
  );

  test('enforces the byte cap and accepts its exact boundary', () {
    expect(
      () => NativeRiggedModelProbeOptions(
        glbBytes: _header(NativeRiggedModelProbeOptions.maxGlbBytes + 1),
        latitude: 0,
        longitude: 0,
      ),
      throwsArgumentError,
    );
    final options = NativeRiggedModelProbeOptions(
      glbBytes: _header(NativeRiggedModelProbeOptions.maxGlbBytes),
      latitude: 0,
      longitude: 0,
    );
    expect(options.glbBytes.length, NativeRiggedModelProbeOptions.maxGlbBytes);
  });

  test('rejects invalid coordinates and geometry before transport', () {
    for (final latitude in [double.nan, double.infinity, 85.1, -85.1]) {
      expect(
        () => NativeRiggedModelProbeOptions(
          glbBytes: _header(),
          latitude: latitude,
          longitude: 0,
        ),
        throwsArgumentError,
      );
    }
    for (final longitude in [double.nan, double.infinity, 181.0]) {
      expect(
        () => NativeRiggedModelProbeOptions(
          glbBytes: _header(),
          latitude: 0,
          longitude: longitude,
        ),
        throwsArgumentError,
      );
    }
    for (final height in [0.0, -1.0, double.infinity]) {
      expect(
        () => NativeRiggedModelProbeOptions(
          glbBytes: _header(),
          latitude: 0,
          longitude: 0,
          heightMeters: height,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => NativeRiggedModelProbeOptions(
        glbBytes: _header(),
        latitude: 0,
        longitude: 0,
        headingDegrees: double.nan,
      ),
      throwsArgumentError,
    );
    expect(
      () => NativeRiggedModelProbeOptions(
        glbBytes: _header(),
        latitude: 0,
        longitude: 0,
        altitudeMeters: double.infinity,
      ),
      throwsArgumentError,
    );
  });

  test('accepts stationary playback and rejects invalid rate or clip', () {
    for (final rate in [0.0, 1.0, 4.0]) {
      expect(
        () => NativeRiggedModelProbeOptions(
          glbBytes: _header(),
          latitude: 0,
          longitude: 0,
          playbackRate: rate,
        ),
        returnsNormally,
      );
    }
    for (final rate in [-0.1, 4.1, double.nan, double.infinity]) {
      expect(
        () => NativeRiggedModelProbeOptions(
          glbBytes: _header(),
          latitude: 0,
          longitude: 0,
          playbackRate: rate,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => NativeRiggedModelProbeOptions(
        glbBytes: _header(),
        latitude: 0,
        longitude: 0,
        clipIndex: -1,
      ),
      throwsArgumentError,
    );
  });
}
