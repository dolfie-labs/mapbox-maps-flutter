// This device test exercises the experimental cube, not glTF or skeletons.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

const _waitLimit = Duration(seconds: 60);
const _pollInterval = Duration(milliseconds: 100);
const _layerId = 'movey-animated-entities-p0-cube-v1';
const _latitude = 10.7769;
const _longitude = 106.7009;

String _blankStyle(String name, String color) => jsonEncode({
  'version': 8,
  'name': name,
  'projection': {'name': 'mercator'},
  'sources': <String, Object>{},
  'layers': [
    {
      'id': 'probe-background',
      'type': 'background',
      'paint': {'background-color': color},
    },
  ],
});

/// Start native operations and all timeout/delay timers in real time, even if
/// a test runner supplies a fake clock. Preserve errors outside runAsync,
/// whose default behavior otherwise reports and replaces them with null.
Future<T> _native<T>(
  WidgetTester tester,
  Future<T> Function() operation, {
  Duration timeout = _waitLimit,
}) async {
  late T value;
  Object? failure;
  StackTrace? failureStack;
  await tester.runAsync(() async {
    try {
      value = await operation().timeout(timeout);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
  });
  final error = failure;
  if (error != null) Error.throwWithStackTrace(error, failureStack!);
  return value;
}

Future<T> _poll<T>(
  WidgetTester tester,
  Future<T?> Function() read, {
  required String description,
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < _waitLimit) {
    // Keep the platform view composited without pumpAndSettle: native repaint
    // is intentionally continuous while the cube rotates.
    await tester.pump();
    final remaining = _waitLimit - watch.elapsed;
    if (remaining <= Duration.zero) break;
    final result = await _native<T?>(tester, read, timeout: remaining);
    if (result != null) return result;
    await _native<void>(tester, () => Future<void>.delayed(_pollInterval));
  }
  throw TimeoutException('Timed out waiting for $description', _waitLimit);
}

Future<NativeCustomLayerProbeDiagnostics> _waitForProbe(
  WidgetTester tester,
  MapboxMap map,
  bool Function(NativeCustomLayerProbeDiagnostics) ready, {
  required String description,
}) => _poll<NativeCustomLayerProbeDiagnostics>(tester, () async {
  final state = await map.nativeCustomLayerProbe.getDiagnostics();
  expect(state.supportsSkeletalAnimation, isFalse);
  expect(state.lastErrorCode, isNull, reason: description);
  return ready(state) ? state : null;
}, description: description);

Map<String, Object?> _observation(
  String checkpoint,
  NativeCustomLayerProbeDiagnostics state,
) => {
  'checkpoint': checkpoint,
  'backend': state.backend.name,
  'attached': state.attached,
  'paused': state.paused,
  'styleLayerPresent': state.styleLayerPresent,
  'initialized': state.initialized,
  'repaintEnabled': state.repaintEnabled,
  'renderedFrames': state.renderedFrames,
  'lastErrorCode': state.lastErrorCode,
  'incomingGlErrorCode': state.incomingGlErrorCode,
  'supportsSkeletalAnimation': state.supportsSkeletalAnimation,
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native cube survives camera changes, pause, style reload and detach',
    (tester) async {
      const token = String.fromEnvironment('ACCESS_TOKEN');
      expect(
        token.isNotEmpty,
        isTrue,
        reason:
            'Supply ACCESS_TOKEN with --dart-define or --dart-define-from-file.',
      );
      expect(
        token.startsWith('pk.'),
        isTrue,
        reason: 'ACCESS_TOKEN must be a public Mapbox token.',
      );
      MapboxOptions.setAccessToken(token);

      final observations = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'status': 'running',
        'protocolVersion': 1,
        'platform': defaultTargetPlatform.name,
        'verification':
            'Native draw diagnostics; visual output needs screenshot inspection.',
        'observations': observations,
      };
      binding.reportData = {'nativeCustomLayerProbe': report};

      MapboxMap? createdMap;
      var idleEvents = 0;
      var styleEvents = 0;
      final mapErrorTypes = <String>[];
      final checkpoint = ValueNotifier('P0 cube: creating map');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _native<void>(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        checkpoint.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                MapWidget(
                  key: const ValueKey('native-cube-probe-map'),
                  // The public widget accepts URIs only. Apply the local blank
                  // style immediately after creation, as other SDK tests do.
                  styleUri: '',
                  onMapCreated: (map) => createdMap = map,
                  onMapIdleListener: (_) => idleEvents++,
                  onStyleLoadedListener: (_) => styleEvents++,
                  onMapLoadErrorListener: (error) =>
                      mapErrorTypes.add(error.type.name),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: ValueListenableBuilder<String>(
                          valueListenable: checkpoint,
                          builder: (_, value, _) => Text(value),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final map = await _poll<MapboxMap>(
        tester,
        () async => createdMap,
        description: 'native MapWidget creation',
      );
      final initialIdleEvents = idleEvents;
      final initialStyleEvents = styleEvents;
      await _native<void>(
        tester,
        () => map.loadStyleJson(_blankStyle('p0-probe-initial', '#202834')),
      );
      await _poll<bool>(tester, () async {
        return idleEvents > initialIdleEvents &&
                styleEvents > initialStyleEvents
            ? true
            : null;
      }, description: 'first blank Mercator style and map idle');

      // Size-dependent camera work and cube placement start after layout/idle.
      await _native<void>(
        tester,
        () => map.setCamera(
          CameraOptions(
            center: Point(coordinates: Position(_longitude, _latitude)),
            zoom: 17,
            pitch: 45,
            bearing: 0,
          ),
        ),
      );
      await tester.pump();
      await _native<void>(
        tester,
        () => map.nativeCustomLayerProbe.attachCube(
          NativeCubeProbeOptions(
            latitude: _latitude,
            longitude: _longitude,
            sizeMeters: 60,
          ),
        ),
      );
      final attached = await _waitForProbe(
        tester,
        map,
        (state) =>
            state.attached &&
            state.initialized &&
            state.styleLayerPresent &&
            state.repaintEnabled &&
            state.renderedFrames >= 2,
        description: 'native cube initialization and draw submissions',
      );
      expect(
        attached.backend,
        defaultTargetPlatform == TargetPlatform.android
            ? NativeCustomLayerProbeBackend.androidGLES
            : NativeCustomLayerProbeBackend.iosMetal,
      );
      observations.add(_observation('attached', attached));
      checkpoint.value = 'P0 cube: camera change';

      await _native<void>(
        tester,
        () => map.setCamera(CameraOptions(bearing: 72, pitch: 65)),
      );
      final moved = await _waitForProbe(
        tester,
        map,
        (state) => state.renderedFrames > attached.renderedFrames,
        description: 'draw progress after bearing/pitch change',
      );
      final camera = await _native(tester, map.getCameraState);
      expect(camera.bearing, closeTo(72, 0.01));
      expect(camera.pitch, closeTo(65, 0.01));
      observations.add(_observation('camera_changed', moved));
      report['camera'] = {'bearing': camera.bearing, 'pitch': camera.pitch};

      await _native<void>(
        tester,
        () => map.nativeCustomLayerProbe.setPaused(true),
      );
      final paused = await _waitForProbe(
        tester,
        map,
        (state) => state.paused && !state.repaintEnabled,
        description: 'native repaint pause',
      );
      observations.add(_observation('paused_capture', paused));
      checkpoint.value = 'P0 cube: paused capture';
      await tester.pump();
      debugPrint('P0_CUBE_PAUSED_CAPTURE');
      // A real-time capture window for adb/simctl, not a Dart render ticker.
      await _native<void>(
        tester,
        () => Future<void>.delayed(const Duration(seconds: 5)),
      );

      checkpoint.value = 'P0 cube: resumed';
      await _native<void>(
        tester,
        () => map.nativeCustomLayerProbe.setPaused(false),
      );
      final resumed = await _waitForProbe(
        tester,
        map,
        (state) =>
            !state.paused &&
            state.repaintEnabled &&
            state.renderedFrames > paused.renderedFrames,
        description: 'native draw progress after resume',
      );
      observations.add(_observation('resumed', resumed));

      checkpoint.value = 'P0 cube: style reload';
      final previousStyleEvents = styleEvents;
      await _native<void>(
        tester,
        () => map.loadStyleJson(_blankStyle('p0-probe-reloaded', '#364452')),
      );
      final restored = await _waitForProbe(
        tester,
        map,
        (state) =>
            styleEvents > previousStyleEvents &&
            state.attached &&
            state.initialized &&
            state.styleLayerPresent &&
            state.renderedFrames > resumed.renderedFrames,
        description: 'custom layer restoration after style reload',
      );
      final layers = await _native(tester, map.getStyleLayers);
      expect(layers.where((layer) => layer?.id == _layerId), hasLength(1));
      final style =
          jsonDecode(await _native(tester, map.getStyleJSON))
              as Map<String, dynamic>;
      expect(style['name'], 'p0-probe-reloaded');
      observations.add(_observation('style_reloaded', restored));
      report['reservedLayerCountAfterReload'] = 1;

      checkpoint.value = 'P0 cube: detached';
      await _native<void>(tester, map.nativeCustomLayerProbe.detach);
      final detached = await _waitForProbe(
        tester,
        map,
        (state) =>
            !state.attached &&
            !state.styleLayerPresent &&
            !state.repaintEnabled,
        description: 'native cube detach',
      );
      expect(
        await _native(tester, () => map.styleLayerExists(_layerId)),
        isFalse,
      );
      observations.add(_observation('detached', detached));
      report['mapIdleEvents'] = idleEvents;
      report['styleLoadedEvents'] = styleEvents;
      report['mapLoadErrorTypes'] = mapErrorTypes;
      report['status'] = 'completed';
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip:
        kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS),
  );
}
