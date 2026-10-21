// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

const _timeout = Duration(seconds: 60);
const _backgroundId = 'rigged-probe-background';
const _tan = <double>[
  .30699931892751636,
  .10653922395082352,
  .039681909478526005,
];
const _deep = <double>[
  .1192801876221121,
  .039681909478526005,
  .017389102368488736,
];
const _blue = <double>[
  .039681909478526005,
  .25295007623137683,
  .6559306827469925,
];

String _style(String name, {String backgroundId = _backgroundId}) =>
    jsonEncode({
      'version': 8,
      'name': name,
      'projection': {'name': 'mercator'},
      'sources': <String, Object>{},
      'layers': [
        {
          'id': backgroundId,
          'type': 'background',
          'paint': {'background-color': '#202834'},
        },
      ],
    });

Future<T> _native<T>(
  WidgetTester tester,
  Future<T> Function() operation, {
  Duration timeout = _timeout,
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
  Future<T?> Function() read,
  String description,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < _timeout) {
    await tester.pump();
    final remaining = _timeout - watch.elapsed;
    if (remaining <= Duration.zero) break;
    final value = await _native(tester, read, timeout: remaining);
    if (value != null) return value;
    await _native<void>(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  throw TimeoutException('Timed out waiting for $description', _timeout);
}

Future<NativeRiggedModelProbeDiagnostics> _waitModel(
  WidgetTester tester,
  MapboxMap map,
  bool Function(NativeRiggedModelProbeDiagnostics) ready,
  String description,
) => _poll<NativeRiggedModelProbeDiagnostics>(tester, () async {
  final value = await map.nativeRiggedModelProbe.getDiagnostics();
  expect(value.protocolVersion, 1);
  expect(value.lastErrorCode, isNull, reason: description);
  return ready(value) ? value : null;
}, description);

Map<String, Object?> _record(
  String stage,
  NativeRiggedModelProbeDiagnostics value,
) => {
  'stage': stage,
  'protocolVersion': value.protocolVersion,
  'backend': value.backend.name,
  'requested': value.requested,
  'ready': value.ready,
  'paused': value.paused,
  'repaintEnabled': value.repaintEnabled,
  'renderedFrames': value.renderedFrames,
  'poseRevision': value.poseRevision,
  'animationTimeSeconds': value.animationTimeSeconds,
  'vertexCount': value.vertexCount,
  'jointCount': value.jointCount,
  'clipCount': value.clipCount,
  'clipIndex': value.clipIndex,
  'lastErrorCode': value.lastErrorCode,
  'incomingGlErrorCode': value.incomingGlErrorCode,
  'opacity': value.opacity,
  'targetOpacity': value.targetOpacity,
  'isOpacityAnimating': value.isOpacityAnimating,
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Movey V5 wardrobe uses one animated native rig and palette uniforms',
    (tester) async {
      const token = String.fromEnvironment('ACCESS_TOKEN');
      expect(token.startsWith('pk.'), isTrue);
      MapboxOptions.setAccessToken(token);
      final records = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'status': 'running',
        'asset': 'MoveyV5.glb',
        'observations': records,
      };
      binding.reportData = {'moveyCharacterWardrobe': report};
      MapboxMap? created;
      var idle = 0, styles = 0;
      final label = ValueNotifier('Movey V5 wardrobe: preparing native rig');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _native<void>(
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
                  onMapIdleListener: (_) => idle++,
                  onStyleLoadedListener: (_) => styles++,
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: ValueListenableBuilder<String>(
                          valueListenable: label,
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
        () async => created,
        'map creation',
      );
      final beforeIdle = idle, beforeStyle = styles;
      await _native<void>(
        tester,
        () => map.loadStyleJson(_style('movey-v5-wardrobe')),
      );
      await _poll<bool>(
        tester,
        () async => idle > beforeIdle && styles > beforeStyle ? true : null,
        'style and first idle',
      );
      await _native<void>(
        tester,
        () => map.setCamera(
          CameraOptions(
            center: Point(coordinates: Position(106.7009, 10.7769)),
            zoom: 19.5,
            pitch: 45,
          ),
        ),
      );
      final asset = await _native(
        tester,
        () => rootBundle.load('assets/animated_entities/MoveyV5.glb'),
      );
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final header = ByteData.sublistView(bytes);
      final jsonLength = header.getUint32(12, Endian.little);
      final gltf =
          jsonDecode(utf8.decode(bytes.sublist(20, 20 + jsonLength)))
              as Map<String, dynamic>;
      final meshes = gltf['meshes'] as List<dynamic>;
      final partCount = meshes.fold<int>(
        0,
        (sum, mesh) =>
            sum +
            ((mesh as Map<String, dynamic>)['primitives'] as List<dynamic>)
                .length,
      );
      expect(partCount, 9);
      report['meshPartCount'] = partCount;
      report['assetBytes'] = bytes.length;
      report['comparisonAsset'] = 'MoveyCustomizerDynamic.glb (all 002)';
      report['colorSpace'] = 'LINEAR_SRGB';
      Future<void> attach({
        double opacity = 1,
        bool paused = false,
        Uint8List? model,
        List<double>? skin,
        List<double>? eye,
      }) => _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.attachRiggedModel(
          NativeRiggedModelProbeOptions(
            glbBytes: model ?? bytes,
            latitude: 10.7769,
            longitude: 106.7009,
            heightMeters: 40,
            headingDegrees: 0,
            clipIndex: 0,
            opacity: opacity,
            paused: paused,
            skinColorLinear: skin,
            eyeColorLinear: eye,
          ),
        ),
      );
      await attach(opacity: 0, paused: true);
      final hidden = await _waitModel(
        tester,
        map,
        (value) => value.ready && value.opacity == 0 && value.paused,
        'hidden GPU prewarm',
      );
      expect(hidden.jointCount, 57);
      expect(hidden.clipCount, 3);
      expect(hidden.renderedFrames, 0);
      records.add(_record('hidden_prewarm', hidden));
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: 10.7769,
            longitude: 106.7009,
            headingDegrees: 0,
            opacity: 1,
            opacityTransitionMilliseconds: 220,
          ),
        ),
      );
      final revealed = await _waitModel(
        tester,
        map,
        (value) =>
            value.opacity == 1 &&
            value.renderedFrames > 2 &&
            value.isOpacityAnimating == false,
        'paused reveal',
      );
      expect(revealed.animationTimeSeconds, closeTo(0, 1e-9));
      records.add(_record('revealed', revealed));
      Future<void> capture(String marker, String title) async {
        label.value = title;
        await tester.pump();
        await _native<void>(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 600)),
        );
        debugPrint(marker);
        await _native<void>(
          tester,
          () => Future<void>.delayed(const Duration(seconds: 3)),
        );
      }

      Future<Uint8List> load(String name) => _native(tester, () async {
        final data = await rootBundle.load('assets/animated_entities/$name');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      });
      Future<void> waitStatic(String stage) async {
        final value = await _waitModel(
          tester,
          map,
          (value) => value.ready && value.paused && value.renderedFrames > 0,
          stage,
        );
        expect(value.animationTimeSeconds, closeTo(0, 1e-9));
        records.add(_record(stage, value));
      }

      final comparisonBytes = await load('MoveyCustomizerDynamic.glb');
      await attach(paused: true, model: comparisonBytes);
      await waitStatic('dynamic_original');
      await capture(
        'MOVEY_CHARACTER_DEFAULT_CAPTURE',
        'Customizer V5 • dynamic Original / Brown',
      );
      await attach(
        paused: true,
        model: await load('MoveyCustomizerBakedOriginal.glb'),
      );
      await waitStatic('baked_original');
      await capture(
        'MOVEY_CUSTOMIZER_BAKED_ORIGINAL_CAPTURE',
        'Customizer V5 • Blender baked Original / Brown',
      );
      await attach(
        paused: true,
        model: comparisonBytes,
        skin: _tan,
        eye: _blue,
      );
      await waitStatic('dynamic_tan_blue');
      await capture(
        'MOVEY_CUSTOMIZER_TAN_BLUE_CAPTURE',
        'Customizer V5 • dynamic Tan / Blue',
      );
      await attach(
        paused: true,
        model: await load('MoveyCustomizerBakedTanBlue.glb'),
      );
      await waitStatic('baked_tan_blue');
      await capture(
        'MOVEY_CUSTOMIZER_BAKED_TAN_BLUE_CAPTURE',
        'Customizer V5 • Blender baked Tan / Blue',
      );
      await attach(paused: true);
      await waitStatic('dynamic_original_restored');
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.setPaused(false),
      );
      final animated = await _waitModel(
        tester,
        map,
        (value) => value.animationTimeSeconds > 0.45 && value.poseRevision > 2,
        'native animation',
      );
      records.add(_record('animated', animated));
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.setPaused(true),
      );
      await _waitModel(
        tester,
        map,
        (value) => value.paused && !value.repaintEnabled,
        'settled pause',
      );
      await _native<void>(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      final beforePalette = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: 10.7769,
            longitude: 106.7009,
            headingDegrees: 0,
            skinColorLinear: _deep,
            eyeColorLinear: _blue,
          ),
        ),
      );
      final palette = await _waitModel(
        tester,
        map,
        (value) =>
            value.ready && value.renderedFrames > beforePalette.renderedFrames,
        'palette uniform draw',
      );
      expect(
        palette.animationTimeSeconds,
        closeTo(beforePalette.animationTimeSeconds, 1e-9),
      );
      expect(palette.poseRevision, beforePalette.poseRevision);
      expect(palette.vertexCount, beforePalette.vertexCount);
      records.add(_record('dark_skin_blue_eyes', palette));
      label.value = 'Movey V5 • dark skin and blue eyes';
      await tester.pump();
      debugPrint('MOVEY_CHARACTER_DARK_BLUE_CAPTURE');
      await _native<void>(
        tester,
        () => Future<void>.delayed(const Duration(seconds: 5)),
      );
      final phase = palette.animationTimeSeconds;
      await attach(paused: true, skin: _deep, eye: _blue);
      final replaced = await _waitModel(
        tester,
        map,
        (value) => value.ready && value.renderedFrames > 0 && value.paused,
        'same-rig outfit reattach',
      );
      expect(replaced.animationTimeSeconds, closeTo(phase, 1e-6));
      records.add(_record('same_rig_replacement_phase', replaced));
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: 10.7769,
            longitude: 106.7009,
            headingDegrees: 0,
            opacity: 0,
            opacityTransitionMilliseconds: 220,
          ),
        ),
      );
      final faded = await _waitModel(
        tester,
        map,
        (value) =>
            value.ready &&
            value.opacity == 0 &&
            !value.repaintEnabled &&
            value.isOpacityAnimating == false,
        'paused hide',
      );
      records.add(_record('hidden_cached', faded));
      expect(faded.animationTimeSeconds, closeTo(phase, 1e-6));
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: 10.7769,
            longitude: 106.7009,
            headingDegrees: 0,
            opacity: 1,
            opacityTransitionMilliseconds: 220,
          ),
        ),
      );
      final restored = await _waitModel(
        tester,
        map,
        (value) =>
            value.ready &&
            value.opacity == 1 &&
            value.renderedFrames > faded.renderedFrames &&
            value.isOpacityAnimating == false,
        'cached reveal',
      );
      records.add(_record('cached_reveal', restored));
      expect(restored.animationTimeSeconds, closeTo(phase, 1e-6));
      // Real bounded-heap regression: repeated 2K-atlas replacements must decode
      // while the accepted actor remains alive, without accumulating CPU images.
      for (var index = 0; index < 6; index++) {
        await attach(paused: true, skin: _deep, eye: _blue);
        final repeated = await _waitModel(
          tester,
          map,
          (value) => value.ready && value.paused && value.renderedFrames > 0,
          'replacement memory regression $index',
        );
        expect(repeated.animationTimeSeconds, closeTo(phase, 1e-6));
        records.add(_record('replacement_memory_$index', repeated));
      }
      final previousStyles = styles;
      await _native<void>(
        tester,
        () => map.loadStyleJson(_style('movey-v5-texture-context-recovery')),
      );
      await _poll<bool>(
        tester,
        () async => styles > previousStyles ? true : null,
        'replacement style',
      );
      final recovered = await _waitModel(
        tester,
        map,
        (value) => value.ready && value.paused && value.renderedFrames > 0,
        'texture context recovery from compressed source',
      );
      expect(recovered.animationTimeSeconds, closeTo(phase, 1e-6));
      records.add(_record('style_texture_recovery', recovered));
      await capture(
        'MOVEY_CHARACTER_RECOVERY_CAPTURE',
        'Movey V5 • dark skin and blue eyes',
      );
      await _native<void>(tester, map.nativeRiggedModelProbe.detach);
      report['status'] = 'completed';
      debugPrint('MOVEY_WARDROBE_REPORT ${jsonEncode(report)}');
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip:
        kIsWeb ||
        ![
          TargetPlatform.android,
          TargetPlatform.iOS,
        ].contains(defaultTargetPlatform),
  );
}
