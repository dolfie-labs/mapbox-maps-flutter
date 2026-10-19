import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter_mobile/mapbox_maps_flutter_mobile.dart'
    as mobile;
import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object?> diagnostics() => {
    'protocolVersion': 1,
    'backend': 'androidGLES',
    'attached': true,
    'paused': false,
    'styleLayerPresent': true,
    'initialized': true,
    'repaintEnabled': true,
    'renderedFrames': 12,
    'lastErrorCode': null,
    'supportsSkeletalAnimation': false,
  };

  test(
    'commands remain map-scoped and do not alter original channels',
    () async {
      final calls = <(int, MethodCall)>[];
      final originalCalls = <MethodCall>[];
      final maps = <mobile.MapboxMap>[];
      for (final suffix in [41, 42]) {
        messenger.setMockMethodCallHandler(
          MethodChannel('dev.movey.mapbox.animated_entities.v1.$suffix'),
          (call) async {
            calls.add((suffix, call));
            return call.method == 'getDiagnostics' ? diagnostics() : null;
          },
        );
        messenger.setMockMethodCallHandler(
          MethodChannel('plugins.flutter.io.$suffix'),
          (call) async {
            originalCalls.add(call);
            return null;
          },
        );
        maps.add(mobile.MapboxMap.fromNativeController(suffix));
      }
      addTearDown(() async {
        for (final map in maps) {
          map.dispose();
        }
        await Future<void>.delayed(Duration.zero);
        for (final suffix in [41, 42]) {
          messenger.setMockMethodCallHandler(
            MethodChannel('dev.movey.mapbox.animated_entities.v1.$suffix'),
            null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel('plugins.flutter.io.$suffix'),
            null,
          );
        }
      });

      await maps[0].nativeCustomLayerProbe.attachCube(
        NativeCubeProbeOptions(latitude: 10, longitude: 106),
      );
      await maps[1].nativeCustomLayerProbe.setPaused(true);
      final observation = await maps[1].nativeCustomLayerProbe.getDiagnostics();
      await maps[0].nativeCustomLayerProbe.detach();

      expect(calls.map((entry) => entry.$1), [41, 42, 42, 41]);
      expect(calls.map((entry) => entry.$2.method), [
        'attachCube',
        'setPaused',
        'getDiagnostics',
        'detach',
      ]);
      expect(calls.first.$2.arguments, {
        'protocolVersion': 1,
        'latitude': 10.0,
        'longitude': 106.0,
        'altitudeMeters': 0.0,
        'sizeMeters': 20.0,
        'headingDegrees': 0.0,
        'rotationDegreesPerSecond': 30.0,
        'paused': false,
      });
      expect(originalCalls, isEmpty);
      expect(observation.renderedFrames, 12);
      expect(observation.supportsSkeletalAnimation, isFalse);
    },
  );

  test('commands after map disposal do not reach the native channel', () async {
    var received = 0;
    const channel = MethodChannel('dev.movey.mapbox.animated_entities.v1.43');
    messenger.setMockMethodCallHandler(channel, (call) async {
      received++;
      return null;
    });
    const originalChannel = MethodChannel('plugins.flutter.io.43');
    messenger.setMockMethodCallHandler(originalChannel, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(originalChannel, null);
    });
    final map = mobile.MapboxMap.fromNativeController(43);
    final probe = map.nativeCustomLayerProbe;
    map.dispose();

    await expectLater(probe.setPaused(false), throwsStateError);
    await expectLater(probe.getDiagnostics(), throwsStateError);
    expect(received, 0);
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'malformed diagnostics cannot report a successful skeletal probe',
    () async {
      const channel = MethodChannel('dev.movey.mapbox.animated_entities.v1.44');
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {...diagnostics(), 'supportsSkeletalAnimation': true},
      );
      const originalChannel = MethodChannel('plugins.flutter.io.44');
      messenger.setMockMethodCallHandler(originalChannel, (_) async => null);
      final map = mobile.MapboxMap.fromNativeController(44);
      addTearDown(() async {
        map.dispose();
        await Future<void>.delayed(Duration.zero);
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(originalChannel, null);
      });
      await expectLater(
        map.nativeCustomLayerProbe.getDiagnostics(),
        throwsFormatException,
      );
    },
  );

  test('inherited GL warning remains separate from probe failures', () async {
    const channel = MethodChannel('dev.movey.mapbox.animated_entities.v1.45');
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {...diagnostics(), 'incomingGlErrorCode': 'GL_INVALID_ENUM'},
    );
    const originalChannel = MethodChannel('plugins.flutter.io.45');
    messenger.setMockMethodCallHandler(originalChannel, (_) async => null);
    final map = mobile.MapboxMap.fromNativeController(45);
    addTearDown(() async {
      map.dispose();
      await Future<void>.delayed(Duration.zero);
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(originalChannel, null);
    });

    final observation = await map.nativeCustomLayerProbe.getDiagnostics();

    expect(observation.incomingGlErrorCode, 'GL_INVALID_ENUM');
    expect(observation.lastErrorCode, isNull);
    expect(observation.initialized, isTrue);
    expect(observation.renderedFrames, 12);
    expect(observation.supportsSkeletalAnimation, isFalse);
  });

  test('missing or null incoming GL warning accepts iOS diagnostics', () async {
    const channel = MethodChannel('dev.movey.mapbox.animated_entities.v1.46');
    final response = {...diagnostics(), 'backend': 'iosMetal'};
    messenger.setMockMethodCallHandler(channel, (_) async => response);
    const originalChannel = MethodChannel('plugins.flutter.io.46');
    messenger.setMockMethodCallHandler(originalChannel, (_) async => null);
    final map = mobile.MapboxMap.fromNativeController(46);
    addTearDown(() async {
      map.dispose();
      await Future<void>.delayed(Duration.zero);
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(originalChannel, null);
    });

    final withoutKey = await map.nativeCustomLayerProbe.getDiagnostics();
    expect(withoutKey.backend, NativeCustomLayerProbeBackend.iosMetal);
    expect(withoutKey.incomingGlErrorCode, isNull);
    response['incomingGlErrorCode'] = null;
    final withNull = await map.nativeCustomLayerProbe.getDiagnostics();
    expect(withNull.incomingGlErrorCode, isNull);
  });

  test('rejects a non-string incoming GL warning', () async {
    const channel = MethodChannel('dev.movey.mapbox.animated_entities.v1.47');
    final response = diagnostics();
    messenger.setMockMethodCallHandler(channel, (_) async => response);
    const originalChannel = MethodChannel('plugins.flutter.io.47');
    messenger.setMockMethodCallHandler(originalChannel, (_) async => null);
    final map = mobile.MapboxMap.fromNativeController(47);
    addTearDown(() async {
      map.dispose();
      await Future<void>.delayed(Duration.zero);
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(originalChannel, null);
    });

    for (final value in <Object>[
      1280,
      true,
      ['GL_INVALID_ENUM'],
    ]) {
      response['incomingGlErrorCode'] = value;
      await expectLater(
        map.nativeCustomLayerProbe.getDiagnostics(),
        throwsFormatException,
      );
    }
  });
}
