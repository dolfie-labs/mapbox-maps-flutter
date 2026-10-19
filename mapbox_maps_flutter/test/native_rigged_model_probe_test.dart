// ignore_for_file: experimental_member_use

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:mapbox_maps_flutter_platform_interface/mapbox_maps_flutter_platform_interface_internal.dart';

import 'mapbox_map_test.dart' show MockMapboxMapPlatformInterface;

class FakeRiggedModelProbe implements NativeRiggedModelProbePlatformInterface {
  final calls = <String>[];
  NativeRiggedModelProbeOptions? options;
  NativeRiggedModelProbeUpdate? update;
  bool? paused;
  final diagnostics = const NativeRiggedModelProbeDiagnostics(
    backend: NativeCustomLayerProbeBackend.iosMetal,
    requested: true,
    ready: false,
    paused: false,
    repaintEnabled: true,
    renderedFrames: 0,
    poseRevision: 0,
    animationTimeSeconds: 0,
    vertexCount: 160,
    jointCount: 2,
    clipCount: 1,
    clipIndex: 0,
    lastErrorCode: null,
  );

  @override
  Future<void> attachRiggedModel(NativeRiggedModelProbeOptions options) async {
    calls.add('attach');
    this.options = options;
  }

  @override
  Future<void> updateRiggedModel(NativeRiggedModelProbeUpdate update) async {
    calls.add('update');
    this.update = update;
  }

  @override
  Future<void> setPaused(bool paused) async {
    calls.add('pause');
    this.paused = paused;
  }

  @override
  Future<void> detach() async {
    calls.add('detach');
  }

  @override
  Future<NativeRiggedModelProbeDiagnostics> getDiagnostics() async {
    calls.add('diagnostics');
    return diagnostics;
  }
}

class RiggedMapPlatform extends MockMapboxMapPlatformInterface
    implements NativeRiggedModelProbeProvider {
  final probe = FakeRiggedModelProbe();
  int getterReads = 0;
  @override
  NativeRiggedModelProbePlatformInterface get nativeRiggedModelProbe {
    getterReads++;
    return probe;
  }
}

void main() {
  test(
    'optional rigged facade is lazy, cached and delegates to its provider',
    () async {
      final implementation = RiggedMapPlatform();
      final map = MapboxMap(implementation);
      addTearDown(map.dispose);
      expect(implementation.getterReads, 0);
      final probe = map.nativeRiggedModelProbe;
      expect(map.nativeRiggedModelProbe, same(probe));
      expect(implementation.getterReads, 1);
      final bytes = Uint8List(12);
      final header = ByteData.sublistView(bytes);
      header.setUint32(0, 0x46546c67, Endian.little);
      header.setUint32(4, 2, Endian.little);
      header.setUint32(8, 12, Endian.little);
      final options = NativeRiggedModelProbeOptions(
        glbBytes: bytes,
        latitude: 0,
        longitude: 0,
      );
      await probe.attachRiggedModel(options);
      final update = NativeRiggedModelProbeUpdate(
        latitude: 10,
        longitude: 106,
        headingDegrees: 90,
        clipIndex: 1,
      );
      await probe.updateRiggedModel(update);
      await probe.setPaused(true);
      final state = await probe.getDiagnostics();
      await probe.detach();
      expect(implementation.probe.options, same(options));
      expect(implementation.probe.update, same(update));
      expect(implementation.probe.paused, isTrue);
      expect(state, same(implementation.probe.diagnostics));
      expect(
        state.ready,
        isFalse,
        reason: 'CPU acceptance is not GPU readiness',
      );
      expect(state.supportsSkeletalAnimation, isTrue);
      expect(implementation.probe.calls, [
        'attach',
        'update',
        'pause',
        'diagnostics',
        'detach',
      ]);
    },
  );

  test(
    'the original map implementation does not have to implement rigged probing',
    () async {
      final implementation = MockMapboxMapPlatformInterface();
      final map = MapboxMap(implementation);
      addTearDown(map.dispose);
      expect(() => map.nativeRiggedModelProbe, throwsUnsupportedError);
      await map.loadStyleURI('mapbox://styles/mapbox/dark-v11');
      expect(implementation.loadStyleURICallCount, 1);
    },
  );
}
