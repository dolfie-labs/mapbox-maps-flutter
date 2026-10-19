// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

const _latitude = 10.7769;
const _longitude = 106.7009;
const _timeout = Duration(seconds: 60);

String _style(String name) => jsonEncode({
  'version': 8,
  'name': name,
  'projection': {'name': 'mercator'},
  'sources': <String, Object>{},
  'layers': [
    {
      'id': 'fox-background',
      'type': 'background',
      'paint': {'background-color': '#202834'},
    },
  ],
});

Future<T> _native<T>(WidgetTester tester, Future<T> Function() action) async {
  late T value;
  Object? failure;
  StackTrace? stack;
  await tester.runAsync(() async {
    try {
      value = await action().timeout(_timeout);
    } catch (error, trace) {
      failure = error;
      stack = trace;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  return value;
}

Future<T> _poll<T>(
  WidgetTester tester,
  Future<T?> Function() read,
  String description,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < _timeout) {
    await tester.pump();
    final value = await _native(tester, read);
    if (value != null) return value;
    await _native(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  throw TimeoutException(description, _timeout);
}

Map<String, Object?> _record(
  String stage,
  NativeRiggedModelProbeDiagnostics d,
) => {
  'stage': stage,
  'backend': d.backend.name,
  'requested': d.requested,
  'ready': d.ready,
  'paused': d.paused,
  'repaintEnabled': d.repaintEnabled,
  'renderedFrames': d.renderedFrames,
  'poseRevision': d.poseRevision,
  'animationTimeSeconds': d.animationTimeSeconds,
  'clipIndex': d.clipIndex,
  'clipCount': d.clipCount,
  'vertexCount': d.vertexCount,
  'jointCount': d.jointCount,
  'lastErrorCode': d.lastErrorCode,
  'incomingGlErrorCode': d.incomingGlErrorCode,
  'opacity': d.opacity,
  'targetOpacity': d.targetOpacity,
  'isOpacityAnimating': d.isOpacityAnimating,
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Hidden GPU prewarm and native opacity fades retain the model',
    (tester) async {
      const token = String.fromEnvironment('ACCESS_TOKEN');
      expect(token.startsWith('pk.'), isTrue);
      MapboxOptions.setAccessToken(token);
      final observations = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'status': 'running',
        'platform': defaultTargetPlatform.name,
        'asset': 'Fox.glb',
        'assetBytes': 162852,
        'assetSha256':
            'd97044e701822bac5a62696459b27d7b375aada5de8574ed4362edbba94771f7',
        'clipNames': ['Survey', 'Walk', 'Run'],
        'observations': observations,
        'verification':
            'Hidden GPU readiness, paused native opacity tween, cached placement and repeat reveal; screenshots verify hidden and alpha output.',
      };
      binding.reportData = {'homeCharacterPreload': report};
      MapboxMap? created;
      var styleEvents = 0;
      var idleEvents = 0;
      final label = ValueNotifier('Fox: creating map');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _native(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        label.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                MapWidget(
                  styleUri: '',
                  onMapCreated: (map) => created = map,
                  onStyleLoadedListener: (_) => styleEvents++,
                  onMapIdleListener: (_) => idleEvents++,
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ValueListenableBuilder<String>(
                              valueListenable: label,
                              builder: (_, value, _) => Text(value),
                            ),
                            const Text(
                              'Fox: PixelMannen (CC0) · tomkranis / AsoboStudio / scurest (CC BY 4.0)',
                            ),
                          ],
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
        () async => created,
        'map creation',
      );
      await _native(tester, () => map.loadStyleJson(_style('fox-initial')));
      await _poll<bool>(
        tester,
        () async => styleEvents > 0 && idleEvents > 0 ? true : null,
        'style loaded',
      );
      await _native(
        tester,
        () => map.setCamera(
          CameraOptions(
            center: Point(coordinates: Position(_longitude, _latitude)),
            zoom: 17.6,
            pitch: 45,
          ),
        ),
      );
      final asset = await _native(
        tester,
        () => rootBundle.load('assets/animated_entities/Fox.glb'),
      );
      expect(asset.lengthInBytes, 162852);
      await _native(tester, () async {
        await expectLater(
          map.nativeRiggedModelProbe.updateRiggedModel(
            NativeRiggedModelProbeUpdate(
              latitude: _latitude,
              longitude: _longitude,
              headingDegrees: 90,
            ),
          ),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'MODEL_NOT_ATTACHED',
            ),
          ),
        );
      });
      final warmWatch = Stopwatch()..start();
      await _native(
        tester,
        () => map.nativeRiggedModelProbe.attachRiggedModel(
          NativeRiggedModelProbeOptions(
            glbBytes: asset.buffer.asUint8List(
              asset.offsetInBytes,
              asset.lengthInBytes,
            ),
            latitude: _latitude,
            longitude: _longitude,
            headingDegrees: 90,
            heightMeters: 30,
            paused: true,
            opacity: 0,
          ),
        ),
      );
      Future<NativeRiggedModelProbeDiagnostics> waitModel(
        bool Function(NativeRiggedModelProbeDiagnostics) condition,
        String stage,
      ) => _poll(tester, () async {
        final d = await map.nativeRiggedModelProbe.getDiagnostics();
        expect(d.lastErrorCode, isNull, reason: stage);
        return condition(d) ? d : null;
      }, stage);
      final ready = await waitModel(
        (d) => d.ready && d.opacity == 0 && !d.repaintEnabled,
        'hidden GPU ready without drawing',
      );
      report['hiddenReadyMilliseconds'] = warmWatch.elapsedMilliseconds;
      expect(ready.vertexCount, 1728);
      expect(ready.jointCount, 24);
      expect(ready.clipCount, 3);
      expect(ready.renderedFrames, 0);
      expect(ready.paused, isTrue);
      expect(ready.isOpacityAnimating, isFalse);
      observations.add(_record('hidden_gpu_ready', ready));

      Future<void> captureWindow(String stage) async {
        label.value = 'Fox prewarm: $stage';
        await tester.pump();
        debugPrint('PRELOAD_${stage.toUpperCase()}_CAPTURE');
        await _native(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 2000)),
        );
      }

      await captureWindow('hidden');
      final held = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      expect(held.renderedFrames, ready.renderedFrames);
      expect(held.poseRevision, ready.poseRevision);
      expect(held.animationTimeSeconds, ready.animationTimeSeconds);
      await _native(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: _latitude + .00004,
            longitude: _longitude + .00004,
            headingDegrees: 270,
          ),
        ),
      );
      await _native(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 600)),
      );
      final hiddenGps = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      expect(hiddenGps.ready, isTrue);
      expect(hiddenGps.opacity, 0);
      expect(hiddenGps.repaintEnabled, isFalse);
      expect(hiddenGps.renderedFrames, held.renderedFrames);
      expect(hiddenGps.animationTimeSeconds, held.animationTimeSeconds);
      observations.add(_record('hidden_gps_cached_no_frames', hiddenGps));

      // The long test fade makes a native midpoint observable on both hosts.
      final revealWatch = Stopwatch()..start();
      await _native(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: _latitude + .00004,
            longitude: _longitude + .00004,
            headingDegrees: 270,
            opacity: 1,
            opacityTransitionMilliseconds: 1000,
          ),
        ),
      );
      final middle = await waitModel(
        (d) => d.opacity! > 0 && d.opacity! < 1 && d.isOpacityAnimating!,
        'paused native fade midpoint',
      );
      expect(middle.paused, isTrue);
      expect(middle.animationTimeSeconds, held.animationTimeSeconds);
      expect(middle.ready, isTrue);
      expect(middle.vertexCount, 1728);
      observations.add(_record('paused_fade_midpoint', middle));
      // Repeating target opacity with a GPS/rate update must not restart fading.
      await _native(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: _latitude + .00004,
            longitude: _longitude + .00004,
            headingDegrees: 270,
            opacity: 1,
            opacityTransitionMilliseconds: 1000,
            playbackRate: 1,
          ),
        ),
      );
      final visible = await waitModel(
        (d) => d.opacity == 1 && !d.isOpacityAnimating! && !d.repaintEnabled,
        'fully visible paused endpoint',
      );
      report['firstRevealMilliseconds'] = revealWatch.elapsedMilliseconds;
      expect(visible.renderedFrames, greaterThan(hiddenGps.renderedFrames));
      expect(visible.animationTimeSeconds, held.animationTimeSeconds);
      observations.add(_record('visible_cached_gpu', visible));
      await captureWindow('visible');

      // A stable half-alpha pose verifies actual GPU blending in screenshots.
      await _native(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: _latitude + .00004,
            longitude: _longitude + .00004,
            headingDegrees: 270,
            opacity: .5,
          ),
        ),
      );
      await waitModel(
        (d) => d.opacity == .5 && !d.repaintEnabled,
        'stable half opacity',
      );
      await captureWindow('half_alpha');
      await _native(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: _latitude + .00004,
            longitude: _longitude + .00004,
            headingDegrees: 270,
            opacity: 1,
            opacityTransitionMilliseconds: 220,
          ),
        ),
      );
      await waitModel(
        (d) => d.opacity == 1 && !d.repaintEnabled,
        'app-duration reveal',
      );
      await _native(tester, () => map.nativeRiggedModelProbe.setPaused(false));
      final animated = await waitModel(
        (d) => d.poseRevision > visible.poseRevision + 5,
        'visible pose clock advances',
      );
      await _native(tester, () => map.nativeRiggedModelProbe.setPaused(true));
      final frozen = await waitModel((d) => !d.repaintEnabled, 'paused again');
      expect(frozen.animationTimeSeconds, greaterThan(0));
      observations.add(_record('animated_then_paused', animated));

      await _native(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: _latitude + .00004,
            longitude: _longitude + .00004,
            headingDegrees: 270,
            opacity: 0,
            opacityTransitionMilliseconds: 220,
          ),
        ),
      );
      final hiddenAgain = await waitModel(
        (d) => d.ready && d.opacity == 0 && !d.repaintEnabled,
        'hidden but GPU still cached',
      );
      expect(hiddenAgain.vertexCount, frozen.vertexCount);
      expect(hiddenAgain.animationTimeSeconds, frozen.animationTimeSeconds);
      observations.add(_record('hidden_retains_model_clock', hiddenAgain));
      final cachedWatch = Stopwatch()..start();
      await _native(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: _latitude + .00004,
            longitude: _longitude + .00004,
            headingDegrees: 270,
            opacity: 1,
            opacityTransitionMilliseconds: 220,
          ),
        ),
      );
      final cached = await waitModel(
        (d) => d.opacity == 1 && !d.repaintEnabled,
        'second reveal without reload',
      );
      report['cachedRevealMilliseconds'] = cachedWatch.elapsedMilliseconds;
      expect(cached.ready, isTrue);
      expect(cached.renderedFrames, greaterThan(hiddenAgain.renderedFrames));
      expect(cached.poseRevision, frozen.poseRevision);
      expect(cached.animationTimeSeconds, frozen.animationTimeSeconds);
      observations.add(_record('second_reveal_no_clock_reset', cached));
      await captureWindow('cached_reveal');
      await _native(tester, map.nativeRiggedModelProbe.detach);
      final detached = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      expect(detached.requested, isFalse);
      expect(detached.ready, isFalse);
      expect(detached.repaintEnabled, isFalse);
      observations.add(_record('detached', detached));
      report['status'] = 'completed';
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip:
        kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS),
  );
}
