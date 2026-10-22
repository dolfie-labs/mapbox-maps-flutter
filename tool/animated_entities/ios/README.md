# iOS native CPU checks

Run from the SDK repository root on macOS with the Xcode command-line tools:

```sh
swiftc -module-cache-path /private/tmp/movey-glb-check-cache \
  mapbox_maps_flutter_mobile/ios/mapbox_maps_flutter_mobile/Sources/mapbox_maps_flutter_mobile/Classes/MoveyRiggedModelAsset.swift \
  tool/animated_entities/ios/GLBDecoderChecks.swift \
  -o /private/tmp/movey-glb-check
/private/tmp/movey-glb-check
```

An optional executable argument selects another copy of `RiggedSimple.glb`.
The checks verify the checked-in fixture counts, changing evaluated joint palettes,
grounded unit rest height, quaternion shortest-arc interpolation, STEP sampling,
and selected malformed/unsupported/cancellation paths. They use the same production
decoder and evaluator; they do not compile Metal or prove GPU rendering.

The on-device test is
`mapbox_maps_flutter/example/integration_test/native_rigged_model_probe_test.dart`.
Its `ready` flag follows native GPU buffer creation. Preserve external pose A/B
captures alongside the JSON diagnostics to verify visible deformation.

The optional second GLB argument checks the original Khronos Fox fixture as well:

```sh
/private/tmp/movey-glb-check tool/animated_entities/fixtures/RiggedSimple.glb mapbox_maps_flutter/example/assets/animated_entities/Fox.glb
```

These checks include Fox UVs, the bounded embedded PNG decode, 24 joints and three distinct animated palettes; native clock rate continuity, clip reset primitives, dateline/heading short arcs, placement retarget continuity, and background suspension. The iOS integration test is still required to prove Metal texture upload, skinning, clip switching and placement rendering.

Heading checks also cover eased 180-degree reversals over 1.5s, a separate
500ms position clock, position-only retargets that preserve a turn, heading
retarget continuity and suspension/resume midway through the longer turn.

Opacity checks cover hidden initialization, a fade that advances while the bone
clock is paused, endpoint completion, repeated-target continuity, reversal and
foreground suspension. They do not prove Metal blending or hidden GPU upload;
the native integration fixture must check readiness with zero visible frames,
reveal/hide, no invisible depth writes, and cached-resource reuse.

The character decoder also accepts one shared skin with up to 64 joints, eight
mesh nodes and sixteen primitives, flattened into shared vertex/index buffers.
Limits are 8 MiB per GLB, 1024 accessors/bufferViews, sixteen embedded
textures/images/samplers, 65536 total vertices, 196608 total indices and two
million decoded animation scalars. Aggregate unique decoded texture pixels are
capped at 16,777,216 (64 MiB RGBA) before image decompression; cached texture
indices do not consume the budget twice. The existing per-image and animation-channel
limits remain. CPU checks cover part index offsets, unsupported part counts,
shared-skin enforcement, tint-mask metadata and sRGB palette decoding.

An optional third GLB argument verifies a real Movey V5 assembled character
(57 shared joints and three clips):

```sh
/private/tmp/movey-glb-check tool/animated_entities/fixtures/RiggedSimple.glb \
  mapbox_maps_flutter/example/assets/animated_entities/Fox.glb \
  /path/to/movey-male-outfit-v5.glb
```

The Customizer V5 material modes, exact linear palette transport and legacy
neutral-atlas compatibility are specified in
[`docs/MOVEY_CHARACTER_WARDROBE.md`](../../../docs/MOVEY_CHARACTER_WARDROBE.md).
Omitted Customizer attach colors use the saved Original/Brown references;
omitted updates preserve current colors. `skinColorLinear`/`eyeColorLinear`
arrays take priority over legacy hex fields. Metal uses the original atlas,
authored RGB mask and per-part modes without geometry-based mask heuristics.

The CPU executable also reads `tool/animated_entities/fixtures/customizer-tint-cases.json`:
13 independent one-pixel Cycles emission bakes of the actual saved Blender graph.
It checks skin ratios, Blender HSV iris behavior, adaptive lip brightness,
partial/overlapping masks and protected white against the production Swift
implementation, with a 1e-5 tolerance. The Android counterpart is
`tool/animated_entities/android/CustomizerTintChecks.kt` using the same fixture
and production `RiggedCustomizerTint.kt`. These numerical checks complement,
but do not replace, runtime GPU comparisons.

The full Movey app simulator debug build for the `dev` flavor succeeded against
this local SDK fork on 2026-10-21, compiling the production Swift bridge and
renderer. The same native integration pilot also passed on the iPhone 17 Pro
iOS 26.4 simulator: static Original/Tan-Blue comparisons, uniform-only palette
updates, phase preservation, hidden preparation/reveal and six consecutive
2K-atlas replacements. Screenshots and diagnostics are recorded in the sibling
Movey app `tool/mapbox/reports/wardrobe/customizer-v5/ios/` directory. This is
simulator evidence, without a physical-device performance claim.

Outfit replacement preserves skeletal phase for the same selected clip only
when shared-rig fingerprints, joint names/order, joint parents, rest transforms
and inverse-bind matrices match. The phase is reduced modulo the new clip's
duration; an initial attachment, changed clip or different rig resets it. CPU
checks exercise rig matching, differing joint identity and the retime boundary.

The local full Movey app simulator debug build for the `dev` flavor also
succeeded against the local SDK fork on 2026-10-20. This compiles the production
Swift bridge and renderer; no iOS install or runtime shader validation was done.
