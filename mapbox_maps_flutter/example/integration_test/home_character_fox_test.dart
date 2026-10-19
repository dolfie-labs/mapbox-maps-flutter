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
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Fox texture, three clips, cached native GPS updates',
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
            'Native draws/pose/clock and update continuity; external screenshots verify texture and skeletal shape.',
      };
      binding.reportData = {'homeCharacterFox': report};
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
        (d) => d.ready && d.renderedFrames > 0,
        'Fox GPU ready',
      );
      expect(ready.vertexCount, 1728);
      expect(ready.jointCount, 24);
      expect(ready.clipCount, 3);
      observations.add(_record('ready', ready));
      for (var clip = 0; clip < 3; clip++) {
        final before = await _native(
          tester,
          map.nativeRiggedModelProbe.getDiagnostics,
        );
        await _native(
          tester,
          () => map.nativeRiggedModelProbe.updateRiggedModel(
            NativeRiggedModelProbeUpdate(
              latitude: _latitude,
              longitude: _longitude,
              headingDegrees: 90,
              clipIndex: clip,
              playbackRate: 1,
            ),
          ),
        );
        final selected = await _native(
          tester,
          map.nativeRiggedModelProbe.getDiagnostics,
        );
        expect(selected.ready, isTrue);
        expect(selected.clipIndex, clip);
        expect(
          selected.renderedFrames,
          greaterThanOrEqualTo(before.renderedFrames),
        );
        if (clip != before.clipIndex) expect(selected.animationTimeSeconds, 0);
        await _native(
          tester,
          () => map.nativeRiggedModelProbe.setPaused(false),
        );
        await waitModel(
          (d) =>
              d.poseRevision > selected.poseRevision + 2 &&
              d.renderedFrames > selected.renderedFrames + 2,
          'clip $clip advancing',
        );
        await _native(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await _native(tester, () => map.nativeRiggedModelProbe.setPaused(true));
        await _native(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        final paused = await waitModel(
          (d) => d.paused && !d.repaintEnabled,
          'clip $clip paused and placement settled',
        );
        expect(paused.paused, isTrue);
        expect(paused.repaintEnabled, isFalse);
        expect(paused.lastErrorCode, isNull);
        observations.add(_record('clip_${clip}_paused', paused));
        label.value =
            'Fox clip $clip: ${['Survey (Idle mapping)', 'Walk', 'Run'][clip]} (paused)';
        await tester.pump();
        // A stable external capture window; the app is not driving native poses.
        debugPrint('P0_FOX_CLIP_${clip}_CAPTURE');
        await _native(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 2500)),
        );
        final held = await _native(
          tester,
          map.nativeRiggedModelProbe.getDiagnostics,
        );
        expect(held.poseRevision, paused.poseRevision);
        expect(held.animationTimeSeconds, paused.animationTimeSeconds);
        if (clip == 0) {
          label.value = 'Fox: native GPS/rate update, frozen skeletal pose';
          await tester.pump();
          await _native(
            tester,
            () => map.nativeRiggedModelProbe.updateRiggedModel(
              NativeRiggedModelProbeUpdate(
                latitude: _latitude + .00004,
                longitude: _longitude + .00006,
                headingDegrees: 350,
              ),
            ),
          );
          await _native(
            tester,
            () => map.nativeRiggedModelProbe.updateRiggedModel(
              NativeRiggedModelProbeUpdate(
                latitude: _latitude + .00004,
                longitude: _longitude + .00006,
                headingDegrees: 10,
                playbackRate: .5,
              ),
            ),
          );
          final updated = await _native(
            tester,
            map.nativeRiggedModelProbe.getDiagnostics,
          );
          expect(updated.ready, isTrue);
          expect(updated.clipIndex, 0);
          expect(updated.animationTimeSeconds, held.animationTimeSeconds);
          expect(updated.poseRevision, held.poseRevision);
          expect(
            updated.renderedFrames,
            greaterThanOrEqualTo(held.renderedFrames),
          );
          final settled = await waitModel(
            (d) => !d.repaintEnabled && d.renderedFrames > held.renderedFrames,
            'native placement interpolation settled',
          );
          expect(settled.animationTimeSeconds, held.animationTimeSeconds);
          expect(settled.poseRevision, held.poseRevision);
          expect(settled.ready, isTrue);
          observations.add(
            _record('cached_gps_rate_update_kept_clock_and_mesh', settled),
          );
          debugPrint('P0_FOX_GPS_CAPTURE');
          await _native(
            tester,
            () => Future<void>.delayed(const Duration(milliseconds: 2500)),
          );
          await _native(tester, () async {
            await expectLater(
              map.nativeRiggedModelProbe.updateRiggedModel(
                NativeRiggedModelProbeUpdate(
                  latitude: _latitude,
                  longitude: _longitude,
                  headingDegrees: 90,
                  clipIndex: 99,
                ),
              ),
              throwsA(
                isA<PlatformException>().having(
                  (e) => e.code,
                  'code',
                  'INVALID_ARGUMENTS',
                ),
              ),
            );
          });
          final retained = await _native(
            tester,
            map.nativeRiggedModelProbe.getDiagnostics,
          );
          expect(retained.ready, isTrue);
          expect(retained.clipIndex, 0);
          expect(retained.lastErrorCode, isNull);
        }
      }
      final beforeReload = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      final styleBefore = styleEvents;
      await _native(tester, () => map.loadStyleJson(_style('fox-restored')));
      final restored = await waitModel(
        (d) =>
            styleEvents > styleBefore &&
            d.ready &&
            d.renderedFrames > beforeReload.renderedFrames,
        'texture restoration after style reload',
      );
      observations.add(_record('texture_style_restored', restored));
      final layers = await _native(tester, map.getStyleLayers);
      expect(
        layers.where((layer) => layer != null && layer.id != 'fox-background'),
        hasLength(1),
      );
      report['reservedLayerCountAfterReload'] = 1;
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
