// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

Future<T> _native<T>(WidgetTester tester, Future<T> Function() action) async {
  late T value;
  await tester.runAsync(() async {
    value = await action().timeout(const Duration(seconds: 30));
  });
  return value;
}

Future<NativeRiggedModelProbeDiagnostics> _ready(
  WidgetTester tester,
  NativeRiggedModelProbe probe, {
  int? clip,
  bool animated = true,
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 30)) {
    await tester.pump();
    final status = await _native(tester, probe.getDiagnostics);
    expect(status.lastErrorCode, isNull);
    if (status.ready &&
        (!animated || status.poseRevision > 0) &&
        (clip == null || status.clipIndex == clip)) {
      return status;
    }
    await _native(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  throw TimeoutException('Native actor readiness');
}

String _style(String name) => jsonEncode({
  'version': 8,
  'name': name,
  'sources': <String, Object>{},
  'layers': [
    {
      'id': 'bg',
      'type': 'background',
      'paint': {'background-color': '#202834'},
    },
  ],
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'primary and companion animate, pause, restore and detach independently',
    (tester) async {
      const token = String.fromEnvironment('ACCESS_TOKEN');
      expect(token.startsWith('pk.'), isTrue);
      MapboxOptions.setAccessToken(token);
      MapboxMap? map;
      var idle = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapWidget(
              styleUri: '',
              onMapCreated: (value) => map = value,
              onMapIdleListener: (_) => idle = true,
            ),
          ),
        ),
      );
      final watch = Stopwatch()..start();
      while (map == null && watch.elapsed < const Duration(seconds: 30)) {
        await tester.pump();
        await _native(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      final surface = map!;
      await _native(tester, () => surface.loadStyleJson(_style('two-actors')));
      while (!idle && watch.elapsed < const Duration(seconds: 30)) {
        await tester.pump();
        await _native(
          tester,
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      expect(idle, isTrue);
      await _native(
        tester,
        () => surface.setCamera(
          CameraOptions(
            center: Point(coordinates: Position(106.7009, 10.7769)),
            zoom: 19,
            pitch: 45,
          ),
        ),
      );
      final data = await _native(
        tester,
        () => rootBundle.load('assets/animated_entities/Fox.glb'),
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final player = surface.nativeRiggedModelProbe;
      final pet = surface.nativeCompanionModel;
      Future<void> attach(NativeRiggedModelProbe actor, double longitude) =>
          actor.attachRiggedModel(
            NativeRiggedModelProbeOptions(
              glbBytes: bytes,
              latitude: 10.7769,
              longitude: longitude,
              heightMeters: 9,
            ),
          );
      await _native(tester, () => attach(player, 106.70085));
      await _native(tester, () => attach(pet, 106.70095));
      await _ready(tester, player);
      await _ready(tester, pet);
      await _native(tester, () => pet.setPaused(true));
      final petPaused = await _native(tester, pet.getDiagnostics);
      final playerBefore = await _native(tester, player.getDiagnostics);
      await _native(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      final playerAfter = await _native(tester, player.getDiagnostics);
      final petAfter = await _native(tester, pet.getDiagnostics);
      expect(
        playerAfter.animationTimeSeconds,
        greaterThan(playerBefore.animationTimeSeconds),
      );
      expect(
        petAfter.animationTimeSeconds,
        closeTo(petPaused.animationTimeSeconds, 0.001),
      );
      await _native(
        tester,
        () => pet.updateRiggedModel(
          NativeRiggedModelProbeUpdate(
            latitude: 10.77685,
            longitude: 106.70095,
            headingDegrees: 90,
            clipIndex: 2,
          ),
        ),
      );
      await _native(tester, () => pet.setPaused(false));
      expect((await _ready(tester, pet, clip: 2)).clipIndex, 2);
      expect((await _native(tester, player.getDiagnostics)).clipIndex, 0);
      await _native(
        tester,
        () => surface.loadStyleJson(_style('restored-two-actors')),
      );
      await _ready(tester, player);
      await _ready(tester, pet, clip: 2);
      await _native(tester, pet.detach);
      expect((await _native(tester, pet.getDiagnostics)).requested, isFalse);
      expect((await _ready(tester, player)).ready, isTrue);
      await _native(tester, player.detach);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
