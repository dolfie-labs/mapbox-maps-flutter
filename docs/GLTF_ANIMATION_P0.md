# Native rigged animation P0C

The fork now loads a bounded rigged GLB and animates its skeleton inside Mapbox's
native custom-layer pass: GLES on Android and Metal on iOS. Visible pose A/B
captures passed on an Android emulator and iOS Simulator. This is one experimental
model per map, sharing an exclusive slot with the cube probe.

## Supported input

The common subset is GLB 2 with one embedded buffer, one scene instance of one
mesh/triangle primitive (indexed or non-indexed), one skin with at most 32 joints, and at most
128 nodes. Dense POSITION, JOINTS_0 and float WEIGHTS_0 accessors are supported;
NORMAL is optional. TEXCOORD_0 supports one embedded PNG/JPEG base-color texture,
bounded to 2,048 pixels per side and four million pixels. The renderer supports
nearest/linear filtering, mipmaps and glTF wrap modes; assets without textures
retain their base-color factor. Native evaluators apply hierarchy transforms and inverse-bind
matrices, LINEAR/STEP translation/rotation/scale channels, and quaternion slerp.
Animation uses the original timeline from zero through its last timestamp.
Unsupported structures fail explicitly.

Both backends limit input to 2 MiB and keyframes to 4,096 per channel. Android
limits JSON to 256 KiB/depth 64, vertices/indices to 20,000/60,000, clips to 16,
and decoded accessor scalars to 2,000,000. iOS limits vertices/indices to
65,536/196,608, clips to 8, and decoded animation scalars to 65,536. Use the smaller
limits when preparing portable assets. External images, PBR lighting, morph targets and
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

After CPU acceptance, update placement or select an existing clip without
re-decoding the GLB or reallocating its mesh:

```dart
await probe.updateRiggedModel(NativeRiggedModelProbeUpdate(
  latitude: nextLatitude,
  longitude: nextLongitude,
  headingDegrees: course,
  clipIndex: 1,
));
```

Coordinates and heading interpolate natively over 500 ms, including the short
arc at the dateline/heading wrap. An omitted clip/rate preserves its value;
GPS-only or playback-rate updates preserve accumulated animation time. Only a
changed clip resets its clock. Paused animation can still render placement
interpolation; an inactive application suspends native repaint work entirely.
Updates before acceptance fail with `MODEL_NOT_ATTACHED`; invalid clip/rate or
coordinates fail with `INVALID_ARGUMENTS`.

Attach success means CPU validation accepted the asset. Poll diagnostics for
`ready` after real GPU resource creation; inspect `renderedFrames`,
`poseRevision`, `animationTimeSeconds` and `lastErrorCode`. Draw submission alone
does not prove visible output. `incomingGlErrorCode` records inherited Android
GL warnings separately. Pause on hidden routes as well as app backgrounding.

## Hidden prewarm and native opacity

Set `opacity: 0, paused: true` in `NativeRiggedModelProbeOptions` to prepare
vertex/index buffers, shaders and textures without drawing or writing depth.
`ready == true` with `renderedFrames == 0` is valid for this state. Keep this
single warmed model while the avatar represents the player at far zoom.

Reveal the accepted model with a native-clock fade, then resume animation:

```dart
await probe.updateRiggedModel(NativeRiggedModelProbeUpdate(
  latitude: nextLatitude,
  longitude: nextLongitude,
  headingDegrees: course,
  opacity: 1,
  opacityTransitionMilliseconds: 220,
));
await probe.setPaused(false);
```

Opacity defaults to 1; omitted update fields preserve current visibility.
Opacity is finite in [0, 1]; transition duration is an integer in [0, 1000]
milliseconds and requires opacity. Omitted duration changes opacity immediately.
Defaults preserve original probe rendering. The native opacity clock runs
independently of paused bones, submits the endpoint, then stops repainting.
Repeated targets/GPS updates do not restart a fade. Reversals start from the
current interpolated opacity. Hidden placement snaps to the cached target
without running a placement ticker; reveal uses that latest position.

Diagnostics optionally include `opacity`, `targetOpacity` and
`isOpacityAnimating`; older hosts omit them. Partial opacity uses straight-alpha
blending with depth writes disabled; zero opacity skips drawing entirely.
Hiding retains resources and animation time. Explicit detach, map disposal,
and application-owned background/style/owner cleanup still release the model.
Applications can pair this with a native symbol icon-opacity transition and
start camera flight only after prewarm readiness. A full native rebuild is
required when adding this support to an installed Flutter app.

`integration_test/home_character_preload_test.dart` exercises hidden readiness,
paused fades, repeated targets, cached GPS, alpha output and repeated reveal.
External native captures use the `PRELOAD_*_CAPTURE` log markers. Its latency
observations are emulator/simulator test measurements, not device FPS claims.

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
Walk/Idle clip. Verification also passed 315 Flutter tests, 22 Python validator
tests and Swift CPU decoder checks. Physical-device performance,
multiple independent actors and outfit changes remain unverified or unimplemented.

## Home character fixture

The original Khronos Fox is also included in the example: 1728 non-indexed
vertices, 24 joints, one 1024×1024 embedded PNG and three clips: `Survey` (index
0, used as semantic idle), `Walk` (1), `Run` (2). The file is unchanged; preserve
`Fox.ATTRIBUTION.md`, `Fox.UPSTREAM_README.md` and `Fox.manifest.json` alongside it.
The authored +Z forward axis needs a 180° asset offset when the application
supplies north-based GPS course; do not change the generic glTF basis.

`integration_test/home_character_fox_test.dart` verifies real textured GPU
rendering of all three clips, cached GPS/rate updates, clock/palette retention,
style restoration and detach. Both Android emulator GLES and iOS Simulator
Metal passed this gate. Home location ownership and speed-to-gait policy remain
application responsibilities; this is still a single-model capability.
