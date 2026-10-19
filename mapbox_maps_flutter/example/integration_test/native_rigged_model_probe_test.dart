// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

const _timeout = Duration(seconds: 60);
const _backgroundId = 'rigged-probe-background';

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
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native rigged GLB advances and freezes its skeletal pose',
    (tester) async {
      const token = String.fromEnvironment('ACCESS_TOKEN');
      expect(
        token.isNotEmpty && token.startsWith('pk.'),
        isTrue,
        reason: 'Supply a public ACCESS_TOKEN using dart defines.',
      );
      MapboxOptions.setAccessToken(token);
      final records = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'status': 'running',
        'platform': defaultTargetPlatform.name,
        'asset': 'RiggedSimple.glb',
        'assetBytes': 15104,
        'assetSha256':
            '3a79dabb67bb0cd598a18d08b954d9d357c27c30672f82ef5d3f4e7fe6ca3401',
        'clipIndex': 0,
        'clipName': null,
        'verification':
            'Native pose/draw diagnostics; compare external pose A/B captures.',
        'observations': records,
      };
      binding.reportData = {'nativeRiggedModelProbe': report};
      MapboxMap? created;
      var idleEvents = 0;
      var styleEvents = 0;
      final mapErrorTypes = <String>[];
      final label = ValueNotifier('P0 rigged model: creating map');
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ValueListenableBuilder<String>(
                              valueListenable: label,
                              builder: (_, value, _) => Text(value),
                            ),
                            const Text(
                              'Rigged Simple © 2017 Cesium · CC BY 4.0 · clip 0 (unnamed)',
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
      final idleBefore = idleEvents;
      final styleBefore = styleEvents;
      await _native<void>(
        tester,
        () => map.loadStyleJson(_style('p0-rigged-initial')),
      );
      await _poll<bool>(
        tester,
        () async =>
            idleEvents > idleBefore && styleEvents > styleBefore ? true : null,
        'blank Mercator style and initial map idle',
      );
      await _native<void>(
        tester,
        () => map.setCamera(
          CameraOptions(
            center: Point(coordinates: Position(106.7009, 10.7769)),
            zoom: 17,
            pitch: 45,
          ),
        ),
      );
      final asset = await _native(
        tester,
        () => rootBundle.load('assets/animated_entities/RiggedSimple.glb'),
      );
      expect(asset.lengthInBytes, 15104);
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.attachRiggedModel(
          NativeRiggedModelProbeOptions(
            glbBytes: asset.buffer.asUint8List(
              asset.offsetInBytes,
              asset.lengthInBytes,
            ),
            latitude: 10.7769,
            longitude: 106.7009,
            heightMeters: 40,
          ),
        ),
      );
      final running = await _waitModel(
        tester,
        map,
        (value) =>
            value.requested &&
            value.ready &&
            value.repaintEnabled &&
            value.renderedFrames >= 2 &&
            value.poseRevision >= 2 &&
            value.animationTimeSeconds > 0.05,
        'GPU preparation and native animation',
      );
      expect(
        running.backend,
        defaultTargetPlatform == TargetPlatform.android
            ? NativeCustomLayerProbeBackend.androidGLES
            : NativeCustomLayerProbeBackend.iosMetal,
      );
      expect(running.vertexCount, 160);
      expect(running.jointCount, 2);
      expect(running.clipCount, 1);
      expect(running.clipIndex, 0);
      expect(
        (await _native(
          tester,
          map.nativeCustomLayerProbe.getDiagnostics,
        )).supportsSkeletalAnimation,
        isFalse,
      );
      records.add(_record('running', running));

      Future<NativeRiggedModelProbeDiagnostics> capturePose(String name) async {
        await _native<void>(
          tester,
          () => map.nativeRiggedModelProbe.setPaused(true),
        );
        await _waitModel(
          tester,
          map,
          (value) =>
              value.ready &&
              value.requested &&
              value.paused &&
              !value.repaintEnabled,
          'pause $name',
        );
        await _native<void>(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        final before = await _native(
          tester,
          map.nativeRiggedModelProbe.getDiagnostics,
        );
        expect(before.lastErrorCode, isNull);
        label.value = 'P0 rigged model: pose $name (paused)';
        await tester.pump();
        debugPrint('P0_RIGGED_POSE_$name');
        await _native<void>(
          tester,
          () => Future<void>.delayed(const Duration(seconds: 3)),
        );
        final after = await _native(
          tester,
          map.nativeRiggedModelProbe.getDiagnostics,
        );
        expect(after.lastErrorCode, isNull);
        expect(after.paused, isTrue);
        expect(after.repaintEnabled, isFalse);
        expect(after.poseRevision, before.poseRevision);
        expect(
          after.animationTimeSeconds,
          closeTo(before.animationTimeSeconds, 1e-9),
        );
        records.add(_record('pose_$name', after));
        return after;
      }

      final poseA = await capturePose('A');
      label.value = 'P0 rigged model: playing between captures';
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.setPaused(false),
      );
      final advanced = await _waitModel(
        tester,
        map,
        (value) =>
            !value.paused &&
            value.repaintEnabled &&
            value.poseRevision > poseA.poseRevision + 2 &&
            value.renderedFrames > poseA.renderedFrames &&
            value.animationTimeSeconds > poseA.animationTimeSeconds + 0.45,
        'native skeletal pose and animation time advance',
      );
      records.add(_record('advanced', advanced));
      final poseB = await capturePose('B');
      expect(poseB.poseRevision, greaterThan(poseA.poseRevision));
      expect(
        poseB.animationTimeSeconds,
        greaterThan(poseA.animationTimeSeconds),
      );

      label.value = 'P0 rigged model: restoring style';
      await _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.setPaused(false),
      );
      final styleCount = styleEvents;
      await _native<void>(
        tester,
        () => map.loadStyleJson(_style('p0-rigged-reloaded')),
      );
      final restored = await _waitModel(
        tester,
        map,
        (value) =>
            styleEvents > styleCount &&
            value.requested &&
            value.ready &&
            value.repaintEnabled &&
            value.renderedFrames > 0,
        'rigged model restoration after style reload',
      );
      final redrawn = await _waitModel(
        tester,
        map,
        (value) => value.renderedFrames > restored.renderedFrames,
        'native drawing after style restoration',
      );
      final layers = await _native(tester, map.getStyleLayers);
      final modelLayers = layers
          .where((layer) => layer != null && layer.id != _backgroundId)
          .toList();
      expect(modelLayers, hasLength(1));
      final modelLayerId = modelLayers.single!.id;
      records.add(_record('style_reloaded', redrawn));
      report['reservedLayerId'] = modelLayerId;
      report['reservedLayerCountAfterReload'] = modelLayers.length;

      Future<void> attachModel({Uint8List? bytes}) => _native<void>(
        tester,
        () => map.nativeRiggedModelProbe.attachRiggedModel(
          NativeRiggedModelProbeOptions(
            glbBytes:
                bytes ??
                asset.buffer.asUint8List(
                  asset.offsetInBytes,
                  asset.lengthInBytes,
                ),
            latitude: 10.7769,
            longitude: 106.7009,
            heightMeters: 40,
          ),
        ),
      );
      Future<void> expectOneProbeLayer() async {
        final currentLayers = await _native(tester, map.getStyleLayers);
        final probes = currentLayers
            .where((layer) => layer != null && layer.id != _backgroundId)
            .toList();
        expect(probes, hasLength(1));
        expect(probes.single!.id, modelLayerId);
      }

      // Corrupt JSON while preserving the GLB header and total byte length, so
      // validation reaches the asynchronous native decoder on both backends.
      label.value = 'P0 rigged model: rejecting malformed replacement';
      final beforeFailure = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      final malformed = Uint8List.fromList(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      );
      malformed[20] = 0x21;
      await _native<void>(tester, () async {
        await expectLater(
          map.nativeRiggedModelProbe.attachRiggedModel(
            NativeRiggedModelProbeOptions(
              glbBytes: malformed,
              latitude: 10.7769,
              longitude: 106.7009,
              heightMeters: 40,
            ),
          ),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'GLB_INVALID',
            ),
          ),
        );
      });
      // This deliberately reads directly: the expected load error remains in
      // diagnostics while the previously accepted GPU model keeps animating.
      final retained = await _poll<NativeRiggedModelProbeDiagnostics>(
        tester,
        () async {
          final value = await map.nativeRiggedModelProbe.getDiagnostics();
          return value.requested &&
                  value.ready &&
                  value.vertexCount == 160 &&
                  value.lastErrorCode == 'GLB_INVALID' &&
                  value.poseRevision > beforeFailure.poseRevision + 1
              ? value
              : null;
        },
        'old model after CPU rejection',
      );
      records.add(_record('cpu_failure_old_model_retained', retained));
      await expectOneProbeLayer();
      await attachModel();
      final acceptedAgain = await _waitModel(
        tester,
        map,
        (value) => value.requested && value.ready && value.renderedFrames > 0,
        'valid replacement after CPU rejection',
      );
      records.add(_record('valid_replacement', acceptedAgain));

      label.value = 'P0 rigged model: switching to cube';
      await _native<void>(
        tester,
        () => map.nativeCustomLayerProbe.attachCube(
          NativeCubeProbeOptions(
            latitude: 10.7769,
            longitude: 106.7009,
            sizeMeters: 40,
            paused: true,
          ),
        ),
      );
      final cube = await _poll<NativeCustomLayerProbeDiagnostics>(
        tester,
        () async {
          final value = await map.nativeCustomLayerProbe.getDiagnostics();
          expect(value.lastErrorCode, isNull);
          return value.attached && value.initialized && value.styleLayerPresent
              ? value
              : null;
        },
        'cube after model switch',
      );
      expect(cube.supportsSkeletalAnimation, isFalse);
      expect(cube.paused, isTrue);
      expect(cube.repaintEnabled, isFalse);
      final inactiveModel = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      expect(inactiveModel.requested, isFalse);
      expect(inactiveModel.ready, isFalse);
      expect(inactiveModel.repaintEnabled, isFalse);
      await expectOneProbeLayer();
      report['cubeSwitch'] = {
        'attached': cube.attached,
        'initialized': cube.initialized,
        'modelRequested': inactiveModel.requested,
        'modelReady': inactiveModel.ready,
        'ownedLayerCount': 1,
      };

      label.value = 'P0 rigged model: switching back to model';
      await attachModel();
      final afterCube = await _waitModel(
        tester,
        map,
        (value) => value.requested && value.ready && value.renderedFrames > 0,
        'model after cube switch',
      );
      final inactiveCube = await _native(
        tester,
        map.nativeCustomLayerProbe.getDiagnostics,
      );
      expect(inactiveCube.attached, isFalse);
      expect(inactiveCube.initialized, isFalse);
      expect(inactiveCube.repaintEnabled, isFalse);
      expect(inactiveCube.supportsSkeletalAnimation, isFalse);
      await expectOneProbeLayer();
      records.add(_record('model_restored_after_cube', afterCube));

      await _native<void>(tester, map.nativeRiggedModelProbe.detach);
      final detached = await _waitModel(
        tester,
        map,
        (value) => !value.requested && !value.ready && !value.repaintEnabled,
        'rigged model detach',
      );
      expect(
        await _native(tester, () => map.styleLayerExists(modelLayerId)),
        isFalse,
      );
      records.add(_record('detached', detached));

      label.value = 'P0 rigged model: preserving caller-owned layer';
      await attachModel();
      await _waitModel(
        tester,
        map,
        (value) => value.ready && value.requested,
        'model before caller-layer collision',
      );
      final beforeCollisionStyle = styleEvents;
      await _native<void>(
        tester,
        () => map.loadStyleJson(
          _style('p0-rigged-caller-layer', backgroundId: modelLayerId),
        ),
      );
      final collision = await _poll<NativeRiggedModelProbeDiagnostics>(
        tester,
        () async {
          final value = await map.nativeRiggedModelProbe.getDiagnostics();
          return styleEvents > beforeCollisionStyle &&
                  value.lastErrorCode == 'STYLE_LAYER_ID_CONFLICT'
              ? value
              : null;
        },
        'reserved ID owned by caller style',
      );
      expect(collision.repaintEnabled, isFalse);
      records.add(_record('caller_layer_id_conflict', collision));
      report['collisionDetachCode'] = null;
      await _native<void>(tester, () async {
        try {
          await map.nativeRiggedModelProbe.detach();
        } on PlatformException catch (error) {
          // Android retains the original probe's explicit conflict result;
          // iOS returns success when there is no owned layer left to remove.
          expect(error.code, 'STYLE_LAYER_ID_CONFLICT');
          report['collisionDetachCode'] = error.code;
        }
      });
      // The expected collision error may remain recorded; teardown must still
      // clear native resources and preserve the new style's unrelated layer.
      final collisionDetached = await _native(
        tester,
        map.nativeRiggedModelProbe.getDiagnostics,
      );
      expect(collisionDetached.requested, isFalse);
      expect(collisionDetached.ready, isFalse);
      expect(collisionDetached.repaintEnabled, isFalse);
      expect(
        await _native(tester, () => map.styleLayerExists(modelLayerId)),
        isTrue,
      );
      final callerLayers = await _native(tester, map.getStyleLayers);
      final callerLayer = callerLayers
          .where((layer) => layer?.id == modelLayerId)
          .single!;
      expect(callerLayer.type, 'background');
      report['callerLayerPreserved'] = {
        'id': modelLayerId,
        'type': callerLayer.type,
        'existsAfterDetach': true,
        'expectedError': 'STYLE_LAYER_ID_CONFLICT',
      };
      records.add(_record('caller_layer_conflict_detached', collisionDetached));
      report['mapIdleEvents'] = idleEvents;
      report['styleLoadedEvents'] = styleEvents;
      report['mapLoadErrorTypes'] = mapErrorTypes;
      report['status'] = 'completed';
      label.value = 'P0 rigged model: detached';
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip:
        kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS),
  );
}
