# Movey V5 modular character capability

This local SDK change extends the optional native rigged-model probe used by
Movey. Existing APIs, protocol version, custom-layer ownership, fixture paths
and single-mesh Fox/RiggedSimple inputs remain supported. It does not modify
Mapbox Pigeon bindings or standard model layers.

The native loader accepts one shared skin (up to 64 joints), eight skinned mesh
nodes/16 primitives, embedded opaque base-color materials and a bounded 8MiB
GLB. All parts share the same pose palette and native clock. Each primitive gets
an index range/material; shared textures are decoded/uploaded once per GPU
host. Android releases the decompressed CPU upload cache after successful GPU
upload, retaining bounded compressed image bytes for style/context recovery.
Bitmap conversion uses a row scratch buffer to bound replacement peaks. The app
composes body and selected part GLBs before sending one actor.

Additional bounds: 128 nodes, 1024 accessors/views, 65536 aggregate vertices,
196608 indices, 16 textures/images/samplers, <=2048px/1MiB per image, and
16,777,216 aggregate decoded texture pixels (~64MiB RGBA). Existing finite,
accessor, hierarchy, animation and extension checks remain active. Unsupported
normal/PBR textures, compression, morphs or external image IO still fail.

`NativeRiggedModelProbeOptions` and updates accept `skinColorLinear` and
`eyeColorLinear`: three finite components in [0.001, 1], in linear sRGB. An
explicit linear value takes priority over the corresponding legacy `skinColor`
or `eyeColor` sRGB `#RRGGBB` field. Omitted updates preserve the current palette.
Palette updates change uniforms without decoding/uploading geometry or resetting
the clock. Same-rig outfit replacement preserves current clip time.

The approved V5 Customizer uses the original atlas and authored RGB mask. A
material's `extras.moveyTintMode` selects one of three exact node-graph paths:

- `CUSTOMIZER_V5_HEAD`: sequential skin ratio (mask R), Blender HSV iris shift
  (mask G), then adaptive lip brightness (mask B). A mask texture is required.
- `CUSTOMIZER_V5_SKIN`: whole-material ratio against the original linear skin
  reference, used by body and eyelids.
- `CUSTOMIZER_V5_LIPS`: whole-material adaptive lip brightness.

`extras.moveyTintMaskTexture` points to the embedded mask texture. Its RGB
channels are independent linear weights, sampled without sRGB conversion. Skin
uses target/reference linear RGB; lip brightness is the square root of the
skin/reference luminance ratio clamped to [0.2, 1.2]. Iris hue follows Blender's
wrapped hue offset, saturation ratio clamped to [0, 1], and value ratio clamped
to [0.25, 1.4]. Briefs have a separate untinted material. No geometric eye
heuristic or atlas neutralization is used for these modes.

Customizer attach defaults are the saved graph's Original skin
`[0.88792324, 0.38132605, 0.15592650]` and Brown iris `[0.18, 0.055, 0.022]`.
Legacy materials without `moveyTintMode` retain the neutralized atlas path:
mask R=skin/G=iris or `extras.moveySkin: true`, default sRGB
`#FFD1B0`/`#874721`. These are explicit Movey metadata, not a standard glTF
extension. Both paths decode atlas RGB from sRGB, keep glTF material factors
linear, then encode final output to sRGB.

Android draws within the existing Mapbox GLES custom layer and restores texture
units zero and one plus the previously protected render state. iOS uses one
shared palette buffer and per-part Metal materials. GPS placement, heading,
hidden preparation, paused playback and opacity crossfades retain their existing
lifetimes. The shader remains opaque/unlit; stride calibration and pose blending
are separate work.

Verification is recorded in sibling
`movey-base-app/docs/CHARACTER_RENDERER_VALIDATION.md`. The CPU suite checks real
V5 and a composed mixed female fixture (nine primitives, 57 joints, three clips),
in addition to unchanged Khronos fixtures. The integration test
`example/integration_test/movey_character_wardrobe_test.dart` exercises native
GPU readiness, static comparisons with Blender-baked Original/Tan-Blue assets,
animation, palette-only updates, phase-preserving reattach and hidden reveal.
`tool/animated_entities/fixtures/customizer-tint-cases.json` contains 13
independent Cycles emission probes of the saved Blender material graph; Swift
and Kotlin CPU checks use them to verify the native formula, including partial
masks, iris reflections, lips and protected white. Device performance is not established by a debug emulator run.

The final Customizer pilot passed on Android API 36.1 (read-only SwiftShader
emulator, normal 192 MiB managed heap) and iOS 26.4 (iPhone 17 Pro simulator).
Both recorded 19 stages and six consecutive outfit replacements plus style
reload texture recovery; the paused actor ROI was identical before/after
recovery. This complements the 13 Cycles graph probes and 318 SDK Flutter tests.
Android initial prewarm recorded an inherited `GL_INVALID_ENUM` at the shared
context boundary; owned renderer errors remained null throughout. Descriptive
baked-image comparisons retain JPEG/resampling differences and do not establish
physical-device performance or Blender scene-lighting parity.
