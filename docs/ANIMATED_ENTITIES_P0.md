# Native custom-layer P0 draft

> This document records the historical P0B cube snapshot. For the implemented
> rigged GLB renderer, current evidence and remaining limits, see
> [Native rigged animation P0C](GLTF_ANIMATION_P0.md).

## Status

This patch adds a compile-intended **cube feasibility probe** and an offline
rigged-GLB fixture validator. It has passed Android debug APK and iOS Simulator native compilation. Cube runtime acceptance has passed on Android emulator and iOS Simulator.
Physical-device and production acceptance are still pending. It does not implement GLB loading, skinning, player/pet scenes,
outfit swaps or GPS follow, and must not be presented as a working animated
entity engine.

The patch is now applied to the user's `codex/movey-animated-entities-v3`
checkout. The temporary draft was used to prepare reviewable patches while
filesystem approval was unavailable. No remote release is published yet.

## Added surface

`MapboxMap.nativeCustomLayerProbe` is an optional experimental capability.
Access on web or a custom implementation without the capability throws
`UnsupportedError`; no existing platform interface gains required members.
Existing imports, methods, channels, generated Pigeon schemas and plugin
registrations remain available.

```dart
await map.nativeCustomLayerProbe.attachCube(
  NativeCubeProbeOptions(
    latitude: coordinate.latitude,
    longitude: coordinate.longitude,
    sizeMeters: 20,
  ),
);
final observation = await map.nativeCustomLayerProbe.getDiagnostics();
await map.nativeCustomLayerProbe.setPaused(true);
await map.nativeCustomLayerProbe.detach();
```

Call after map layout and style load, not from an unsized `onMapCreated` camera
path. The sample's fixed coordinate is test data; the app must supply its actual
coordinate through its existing location service after later GPS integration.

The P0-only wire uses `StandardMethodCodec` on
`dev.movey.mapbox.animated_entities.v1.<mapSuffix>`. It has four methods:
`attachCube`, `setPaused`, `detach`, `getDiagnostics`. Every request carries
`protocolVersion: 1`; Dart DTOs validate finite geometry before transport and
native implementations validate it again. This deliberately small manual
bridge does not replace or regenerate any original channel. A production scene
protocol remains gated on the P0 findings.

Native map controllers own one probe host each. Android uses GLES and native
Choreographer repaint; iOS uses Metal and CADisplayLink repaint. The renderers
use Mapbox's custom-layer render pass, with no extra platform view or per-frame
Dart command. Zero angular speed stops continuous repaint. Explicit pause and
foreground lifecycle suspend the animation clock. Style reload restores the
requested cube. GPU resources follow the SDK's native callbacks.

`paused` reports the caller's pause preference; `repaintEnabled` reports current
effective repaint state. `attached` means a cube was requested, not that the GPU
has drawn it. `initialized` means resource/pipeline creation succeeded.
`renderedFrames` counts submitted draws, not completed/presented GPU frames.
`supportsSkeletalAnimation` is always false. Errors are returned or retained in
diagnostics and do not turn into successful model-load events.

The reserved layer ID is `movey-animated-entities-p0-cube-v1`. Initial foreign
layer conflicts fail explicitly and detach does not remove unowned layers.
Applications must not replace that reserved ID while the probe owns it. The
probe does not change the camera, location puck, logo, attribution or telemetry.

## Manual harness

The mobile SDK example catalog adds `native_custom_layer_probe`. Open it after
configuring the example's normal Mapbox access token. It provides attach,
pause/resume, style reload, diagnostics and detach controls. Pan, zoom, pitch and
rotate the map manually. Diagnostics are read on demand; there is no Dart timer.

Only Mercator coordinates within +/-85.05112878 degrees latitude are accepted.
Globe/terrain/depth occlusion are unverified. Test a cube at several zoom levels
and headings. A 20-meter cube is intentionally large enough to inspect at the
sample's zoom 17; it is not a player-size policy.

An application that keeps a map mounted while hidden must call `setPaused` for
route/tab visibility. Native app foreground callbacks alone do not establish
Flutter route visibility. Movey Home integration remains deferred until native
P0 gates pass.

## Fixture

`tool/animated_entities/fixtures/RiggedSimple.glb` is the unchanged Cesium sample
from Khronos glTF Sample Assets, licensed CC-BY-4.0. Its manifest stores the
immutable source commit, byte count, SHA256 and attribution. Actual bytes contain
one skin, two joints and one **unnamed** animation; clip index 0 is not named
Idle/Walk/Run. The Python validator inspects real binary accessors and animation
samples. It is not a full Khronos glTF validator or a native animation evaluator.
See [fixture instructions](../tool/animated_entities/README.md).

The fixture is staged as tooling data, not registered as a Flutter production
asset. No native playback is claimed.

## Verification and remaining gates

Completed locally:

- Android example `flutter build apk --debug` passed with native Kotlin/GLES host.
- iOS Simulator SPM `xcodebuild` passed for arm64 and x86_64, including Swift host.
- Flutter tests: facade 252, mobile 11, platform interface 31; all passed.
- Real native cube integration passed on Android API 36.1 emulator and iPhone 17
  Pro iOS 26.4 Simulator: visible cube, bearing/pitch change, pause/resume, style
  reload with exactly one custom layer, and detach. Screenshots were inspected.
- Android entered initialize with GL_INVALID_ENUM before any probe GL calls.
  Owned initialization stages were independently verified clean, then inherited
  GL warnings were separated into nullable incomingGlErrorCode. Owned resource,
  draw and state-restore errors remain fatal in lastErrorCode.
- Python fixture validator accepted the real GLB/checksum; all 22 tests passed.
- Dart analyzer has no errors after the explicit optional-provider cast fix.
  It reports 10 warnings and 237 infos in upstream source; the workspace is not
  analyzer-clean. No reported diagnostics are in the added probe files.
- `git diff --check` passed for tracked source changes.

Not passed:

- Physical-device output, map/building depth occlusion, context-loss and complete
  background/foreground/route lifecycle testing.
- Real-device animation, performance and leak acceptance.
- GLB loading/skinning/animation and app integration.

The standard Flutter iOS build encounters the example's pre-existing CocoaPods
`objectVersion 70` tooling error. Its existing SPM Xcode project builds directly;
no Podfile/project changes were needed. Swift compilation does not prove runtime
Metal shader creation or visible GPU output.

The cube gate now permits work on GLB skinning and an actual clip. This document
records the P0B snapshot; no skeletal renderer is claimed by that snapshot. Keep
the production Home marker until a real animated-model integration is verified.
