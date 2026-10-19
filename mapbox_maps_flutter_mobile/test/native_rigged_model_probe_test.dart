import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter_mobile/mapbox_maps_flutter_mobile.dart'
    as mobile;
import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface.dart';

Uint8List _header() {
  final bytes = Uint8List(20);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, 0x46546c67, Endian.little);
  view.setUint32(4, 2, Endian.little);
  view.setUint32(8, bytes.length, Endian.little);
  return bytes;
}

Map<String, Object?> _diagnostics() => {
  'protocolVersion': 1,
  'backend': 'androidGLES',
  'requested': true,
  'ready': true,
  'paused': false,
  'repaintEnabled': true,
  'renderedFrames': 12,
  'poseRevision': 8,
  'animationTimeSeconds': 0.5,
  'vertexCount': 160,
  'jointCount': 2,
  'clipCount': 1,
  'clipIndex': 0,
  'lastErrorCode': null,
  'incomingGlErrorCode': 'GL_INVALID_ENUM',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('dev.movey.mapbox.animated_entities.v1.61');
  const original = MethodChannel('plugins.flutter.io.61');
  late mobile.MapboxMap map;
  late List<MethodCall> calls;
  late Map<String, Object?> response;
  var disposed = false;

  setUp(() {
    calls = [];
    response = _diagnostics();
    disposed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'getRiggedModelDiagnostics' ? response : null;
    });
    messenger.setMockMethodCallHandler(original, (_) async => null);
    map = mobile.MapboxMap.fromNativeController(61);
  });
  tearDown(() async {
    if (!disposed) map.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(original, null);
  });

  test(
    'sends copied bytes and exact options on the map-scoped shared channel',
    () async {
      final options = NativeRiggedModelProbeOptions(
        glbBytes: _header(),
        latitude: 10,
        longitude: 106,
      );
      await map.nativeRiggedModelProbe.attachRiggedModel(options);
      await map.nativeRiggedModelProbe.setPaused(true);
      final state = await map.nativeRiggedModelProbe.getDiagnostics();
      await map.nativeRiggedModelProbe.detach();
      expect(calls.map((call) => call.method), [
        'attachRiggedModel',
        'setPaused',
        'getRiggedModelDiagnostics',
        'detach',
      ]);
      expect(calls.first.arguments, {
        'protocolVersion': 1,
        'glbBytes': options.glbBytes,
        'latitude': 10.0,
        'longitude': 106.0,
        'altitudeMeters': 0.0,
        'heightMeters': 20.0,
        'headingDegrees': 0.0,
        'clipIndex': 0,
        'playbackRate': 1.0,
        'paused': false,
        'opacity': 1.0,
      });
      expect(state.protocolVersion, 1);
      expect(state.ready, isTrue);
      expect(state.poseRevision, 8);
      expect(state.animationTimeSeconds, 0.5);
      expect(state.incomingGlErrorCode, 'GL_INVALID_ENUM');
      expect(state.lastErrorCode, isNull);
    },
  );

  test(
    'prepares an invisible model and reveals it with a native fade',
    () async {
      final options = NativeRiggedModelProbeOptions(
        glbBytes: _header(),
        latitude: 10,
        longitude: 106,
        paused: true,
        opacity: 0,
      );
      await map.nativeRiggedModelProbe.attachRiggedModel(options);
      await map.nativeRiggedModelProbe.updateRiggedModel(
        NativeRiggedModelProbeUpdate(
          latitude: 10,
          longitude: 106,
          headingDegrees: 0,
          opacity: 1,
          opacityTransitionMilliseconds: 220,
        ),
      );
      expect((calls.first.arguments as Map)['opacity'], 0.0);
      expect((calls.first.arguments as Map)['paused'], isTrue);
      expect(calls.last.arguments, {
        'protocolVersion': 1,
        'latitude': 10.0,
        'longitude': 106.0,
        'headingDegrees': 0.0,
        'opacity': 1.0,
        'opacityTransitionMilliseconds': 220,
      });
      response = {
        ..._diagnostics(),
        'opacity': 0.5,
        'targetOpacity': 1.0,
        'isOpacityAnimating': true,
      };
      final status = await map.nativeRiggedModelProbe.getDiagnostics();
      expect(status.opacity, 0.5);
      expect(status.targetOpacity, 1);
      expect(status.isOpacityAnimating, isTrue);
    },
  );

  test(
    'validates optional fade diagnostics while accepting older hosts',
    () async {
      final old = await map.nativeRiggedModelProbe.getDiagnostics();
      expect(old.opacity, isNull);
      expect(old.targetOpacity, isNull);
      expect(old.isOpacityAnimating, isNull);
      for (final entry in <MapEntry<String, Object?>>[
        const MapEntry('opacity', -0.1),
        const MapEntry('targetOpacity', 1.1),
        MapEntry('opacity', double.nan),
        const MapEntry('isOpacityAnimating', 1),
      ]) {
        response = {..._diagnostics(), entry.key: entry.value};
        await expectLater(
          map.nativeRiggedModelProbe.getDiagnostics(),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'updates cached model state and omits unspecified clip and rate fields',
    () async {
      await map.nativeRiggedModelProbe.updateRiggedModel(
        NativeRiggedModelProbeUpdate(
          latitude: 10,
          longitude: 106,
          headingDegrees: 359,
          clipIndex: 2,
          playbackRate: 1.5,
        ),
      );
      await map.nativeRiggedModelProbe.updateRiggedModel(
        NativeRiggedModelProbeUpdate(
          latitude: 10.001,
          longitude: 106.002,
          headingDegrees: 1,
        ),
      );
      expect(calls.map((call) => call.method), [
        'updateRiggedModel',
        'updateRiggedModel',
      ]);
      expect(calls.first.arguments, {
        'protocolVersion': 1,
        'latitude': 10.0,
        'longitude': 106.0,
        'headingDegrees': 359.0,
        'clipIndex': 2,
        'playbackRate': 1.5,
      });
      expect(calls.last.arguments, {
        'protocolVersion': 1,
        'latitude': 10.001,
        'longitude': 106.002,
        'headingDegrees': 1.0,
      });
    },
  );

  test('preserves native update failures', () async {
    for (final code in [
      'MODEL_NOT_ATTACHED',
      'INVALID_ARGUMENTS',
      'MAP_DISPOSED',
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code);
      });
      await expectLater(
        map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: 0,
            longitude: 0,
            headingDegrees: 0,
          ),
        ),
        throwsA(
          isA<PlatformException>().having((error) => error.code, 'code', code),
        ),
      );
    }
  });

  test(
    'shares map disposal with the cube channel and blocks later requests',
    () async {
      final probe = map.nativeRiggedModelProbe;
      map.dispose();
      disposed = true;
      await expectLater(probe.getDiagnostics(), throwsStateError);
      await expectLater(probe.setPaused(false), throwsStateError);
      await expectLater(
        probe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: 0,
            longitude: 0,
            headingDegrees: 0,
          ),
        ),
        throwsStateError,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'preserves native loader failure codes without substituting readiness',
    () async {
      for (final code in [
        'GLB_INVALID',
        'GLB_UNSUPPORTED',
        'GLB_TOO_LARGE',
        'LOAD_SUPERSEDED',
        'MAP_DISPOSED',
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: code);
        });
        await expectLater(
          map.nativeRiggedModelProbe.attachRiggedModel(
            NativeRiggedModelProbeOptions(
              glbBytes: _header(),
              latitude: 0,
              longitude: 0,
            ),
          ),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              code,
            ),
          ),
        );
      }
    },
  );

  test(
    'validates protocol, time, counts and optional incoming warning',
    () async {
      for (final entry in <MapEntry<String, Object?>>[
        const MapEntry('protocolVersion', 2),
        const MapEntry('backend', 'unknown'),
        const MapEntry('ready', 1),
        const MapEntry('renderedFrames', -1),
        const MapEntry('poseRevision', -1),
        const MapEntry('vertexCount', -1),
        const MapEntry('jointCount', -1),
        const MapEntry('clipCount', -1),
        const MapEntry('clipIndex', -1),
        const MapEntry('animationTimeSeconds', -0.5),
        MapEntry('animationTimeSeconds', double.nan),
        const MapEntry('lastErrorCode', 7),
        const MapEntry('incomingGlErrorCode', false),
      ]) {
        response = {..._diagnostics(), entry.key: entry.value};
        await expectLater(
          map.nativeRiggedModelProbe.getDiagnostics(),
          throwsFormatException,
          reason: entry.key,
        );
      }
      response = _diagnostics()..remove('incomingGlErrorCode');
      expect(
        (await map.nativeRiggedModelProbe.getDiagnostics()).incomingGlErrorCode,
        isNull,
      );
      response['backend'] = 'iosMetal';
      response['incomingGlErrorCode'] = null;
      expect(
        (await map.nativeRiggedModelProbe.getDiagnostics()).backend,
        NativeCustomLayerProbeBackend.iosMetal,
      );
    },
  );
}
