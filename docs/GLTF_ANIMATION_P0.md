# Native rigged animation P0C

The fork now loads a bounded rigged GLB and animates its skeleton inside Mapbox's
native custom-layer pass: GLES on Android and Metal on iOS. Visible pose A/B
captures passed on an Android emulator and iOS Simulator. This is one experimental
model per map, sharing an exclusive slot with the cube probe.

## Supported input

The common subset is GLB 2 with one embedded buffer, one scene instance of one
untextured mesh/triangle primitive, one skin with at most 32 joints, and at most
128 nodes. Dense POSITION, JOINTS_0 and float WEIGHTS_0 accessors are supported;
NORMAL is optional. Native evaluators apply hierarchy transforms and inverse-bind
matrices, LINEAR/STEP translation/rotation/scale channels, and quaternion slerp.
Animation uses the original timeline from zero through its last timestamp.
Unsupported structures fail explicitly.

Both backends limit input to 2 MiB and keyframes to 4,096 per channel. Android
limits JSON to 256 KiB/depth 64, vertices/indices to 20,000/60,000, clips to 16,
and decoded accessor scalars to 2,000,000. iOS limits vertices/indices to
65,536/196,608, clips to 8, and decoded animation scalars to 65,536. Use the smaller
limits when preparing portable assets. Textures, PBR lighting, morph targets and
extensions are outside this subset.

## Dart use

`MapboxMap.nativeRiggedModelProbe` is a separate optional capability. Custom
platform implementations and web need not implement it. Existing Mapbox APIs,
Pigeon bindings and original channels remain unchanged. The new methods share
the additive map-scoped probe channel; pause/detach control its current model or
cube. The cube capability still reports `supportsSkeletalAnimation == false`.

After layout and first map idle:

```dart
final data = await rootBundle.load('assets/animated_entities/RiggedSimple.glb');
final probe = map.nativeRiggedModelProbe;
await probe.attachRiggedModel(NativeRiggedModelProbeOptions(
  glbBytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  latitude: 10.7769, // Fixed demonstration data.
  longitude: 106.7009,
  heightMeters: 40,
  clipIndex: 0,
));
final observation = await probe.getDiagnostics();
await probe.setPaused(true);
await probe.detach();
```

Attach success means CPU validation accepted the asset. Poll diagnostics for
`ready` after real GPU resource creation; inspect `renderedFrames`,
`poseRevision`, `animationTimeSeconds` and `lastErrorCode`. Draw submission alone
does not prove visible output. `incomingGlErrorCode` records inherited Android
GL warnings separately. Pause on hidden routes as well as app backgrounding.

## Reproduce and evidence

The catalog entry is `native_rigged_model_probe`. From
`mapbox_maps_flutter/example`, provide a local public-token defines file containing
`{"ACCESS_TOKEN":"pk.REPLACE_WITH_PUBLIC_TOKEN"}` and substitute a device ID:

```sh
MAPBOX_PROBE_REPORT_PATH=/private/tmp/native-rigged-model-report.json \
flutter drive -d DEVICE_ID \
  --dart-define-from-file=/absolute/path/mapbox-public-defines.json \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/native_rigged_model_probe_test.dart
```

The driver saves JSON observations, including on failure. Capture the native
screen at `P0_RIGGED_POSE_A` and `P0_RIGGED_POSE_B`; each pause lasts three seconds.
Both backends passed actual GPU drawing, changing skeletal poses, pause/resume,
style restoration with one probe layer, and detach. The expanded CPU-rejection
retention, model↔cube exclusivity and caller-owned layer collision checks passed
on both backends, including the final Android style-ownership and timeline fixes. Android collision detach may return
`STYLE_LAYER_ID_CONFLICT` after cleanup; iOS returns success and retains the
diagnostic. Both must preserve the caller's layer.

The 15,104-byte RiggedSimple fixture has 160 vertices, two joints and one unnamed
clip at index 0. It is unchanged, © 2017 Cesium, CC BY 4.0; preserve its
[attribution and manifest](../tool/animated_entities/README.md). It is not a
Walk/Idle clip. Verification also passed 305 Flutter tests, 22 Python validator
tests and Swift CPU decoder checks. Physical-device performance, ten entities,
GPS follow and outfit changes remain unverified or unimplemented; P1 is pending.
