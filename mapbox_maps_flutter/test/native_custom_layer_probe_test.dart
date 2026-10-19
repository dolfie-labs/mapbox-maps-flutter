// The facade exposes the probe as an experimental optional capability.
// ignore_for_file: experimental_member_use

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface_internal.dart';

import 'mapbox_map_test.dart' show MockMapboxMapPlatformInterface;

class FakeNativeCustomLayerProbe
    implements NativeCustomLayerProbePlatformInterface {
  final calls = <String>[];
  final pauseRequests = <bool>[];
  NativeCubeProbeOptions? lastOptions;
  PlatformException? attachError;

  final diagnostics = const NativeCustomLayerProbeDiagnostics(
    backend: NativeCustomLayerProbeBackend.iosMetal,
    attached: true,
    paused: false,
    styleLayerPresent: true,
    initialized: true,
    repaintEnabled: true,
    renderedFrames: 7,
    lastErrorCode: null,
  );

  @override
  Future<void> attachCube(NativeCubeProbeOptions options) async {
    calls.add('attachCube');
    final error = attachError;
    if (error != null) throw error;
    lastOptions = options;
  }

  @override
  Future<void> setPaused(bool paused) async {
    calls.add('setPaused');
    pauseRequests.add(paused);
  }

  @override
  Future<void> detach() async {
    calls.add('detach');
  }

  @override
  Future<NativeCustomLayerProbeDiagnostics> getDiagnostics() async {
    calls.add('getDiagnostics');
    return diagnostics;
  }
}

class ProbeMapboxMapPlatformInterface extends MockMapboxMapPlatformInterface
    implements NativeCustomLayerProbeProvider {
  final probe = FakeNativeCustomLayerProbe();
  int probeGetterReads = 0;

  @override
  NativeCustomLayerProbePlatformInterface get nativeCustomLayerProbe {
    probeGetterReads++;
    return probe;
  }
}

void main() {
  group('MapboxMap optional native probe facade', () {
    test('resolves the supported capability lazily and caches its facade', () {
      final implementation = ProbeMapboxMapPlatformInterface();
      final map = MapboxMap(implementation);
      addTearDown(map.dispose);

      expect(implementation.probeGetterReads, 0);
      final probe = map.nativeCustomLayerProbe;

      expect(probe, isA<NativeCustomLayerProbe>());
      expect(map.nativeCustomLayerProbe, same(probe));
      expect(implementation.probeGetterReads, 1);
    });

    test(
      'delegates probe commands and diagnostics to the optional provider',
      () async {
        final implementation = ProbeMapboxMapPlatformInterface();
        final map = MapboxMap(implementation);
        addTearDown(map.dispose);
        final options = NativeCubeProbeOptions(
          latitude: 10.7769,
          longitude: 106.7009,
          sizeMeters: 12,
          rotationDegreesPerSecond: 0,
        );
        final probe = map.nativeCustomLayerProbe;

        await probe.attachCube(options);
        await probe.setPaused(true);
        await probe.setPaused(false);
        final diagnostics = await probe.getDiagnostics();
        await probe.detach();

        expect(implementation.probe.lastOptions, same(options));
        expect(implementation.probe.pauseRequests, [true, false]);
        expect(diagnostics, same(implementation.probe.diagnostics));
        expect(implementation.probe.calls, [
          'attachCube',
          'setPaused',
          'setPaused',
          'getDiagnostics',
          'detach',
        ]);
        expect(implementation.loadStyleURICallCount, 0);
        expect(implementation.setCameraCallCount, 0);
      },
    );

    test(
      'keeps the original interface usable without implementing the probe',
      () async {
        // This existing fake implements the full original map interface without
        // noSuchMethod; adding a required probe member would break compilation.
        final implementation = MockMapboxMapPlatformInterface();
        final map = MapboxMap(implementation);
        addTearDown(map.dispose);

        expect(implementation, isNot(isA<NativeCustomLayerProbeProvider>()));
        await map.loadStyleURI('mapbox://styles/mapbox/dark-v11');
        expect(() => map.nativeCustomLayerProbe, throwsUnsupportedError);
        await map.loadStyleURI('mapbox://styles/mapbox/light-v11');

        expect(implementation.loadStyleURICallCount, 2);
        expect(implementation.lastStyleURI, 'mapbox://styles/mapbox/light-v11');
      },
    );

    test(
      'preserves provider failures instead of reporting probe success',
      () async {
        final implementation = ProbeMapboxMapPlatformInterface();
        final map = MapboxMap(implementation);
        addTearDown(map.dispose);
        final failure = PlatformException(code: 'STYLE_LAYER_ADD_FAILED');
        implementation.probe.attachError = failure;

        await expectLater(
          map.nativeCustomLayerProbe.attachCube(
            NativeCubeProbeOptions(latitude: 0, longitude: 0),
          ),
          throwsA(same(failure)),
        );

        expect(implementation.probe.calls, ['attachCube']);
        expect(implementation.probe.lastOptions, isNull);
      },
    );

    test('keeps probe providers isolated between map facades', () async {
      final firstImplementation = ProbeMapboxMapPlatformInterface();
      final secondImplementation = ProbeMapboxMapPlatformInterface();
      final firstMap = MapboxMap(firstImplementation);
      final secondMap = MapboxMap(secondImplementation);
      addTearDown(firstMap.dispose);
      addTearDown(secondMap.dispose);

      await firstMap.nativeCustomLayerProbe.setPaused(true);
      await secondMap.nativeCustomLayerProbe.detach();

      expect(firstImplementation.probe.calls, ['setPaused']);
      expect(firstImplementation.probe.pauseRequests, [true]);
      expect(secondImplementation.probe.calls, ['detach']);
      expect(secondImplementation.probe.pauseRequests, isEmpty);
      expect(
        firstMap.nativeCustomLayerProbe,
        isNot(same(secondMap.nativeCustomLayerProbe)),
      );
    });
  });
}
