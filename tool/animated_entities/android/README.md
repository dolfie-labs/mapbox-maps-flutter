# Android Customizer CPU checks

`PlacementChecks.kt` compiles with production `RiggedPlacement.kt` using the same
Kotlin/JVM toolchain, without Android dependencies. Run
`com.mapbox.maps.mapbox_maps.PlacementChecksKt` to check eased 180-degree turns,
unchanged-heading GPS updates, retarget continuity and dateline/heading short
arcs. Position remains 500ms; heading has a separate 500ms–1.5s eased clock.

`CustomizerTintChecks.kt` compares the production `RiggedCustomizerTint.kt`
implementation with the 13 independent Cycles emission probes in
`../fixtures/customizer-tint-cases.json`. It needs Kotlin/JVM, JDK 17 and
`org.json:json` on the classpath; the SDK Gradle cache already contains these
for local builds. Compile both Kotlin files together and run
`com.mapbox.maps.mapbox_maps.CustomizerTintChecksKt` from the SDK repository
root, passing an optional JSON fixture path. The tolerance is 1e-5 linear RGB.

These CPU checks do not compile GLSL. The native integration pilot is
`mapbox_maps_flutter/example/integration_test/movey_character_wardrobe_test.dart`.
It compares runtime Original/Brown and Tan/Blue with Blender-baked models at
one paused pose/camera, then checks animation, uniform-only color updates,
phase retention, hide/reveal and six consecutive 2K-atlas replacements. The
last sequence also covers a real allocation regression: decoding used to keep
full RGBA arrays after GPU upload while retaining older actors, in addition to
a full-image ARGB scratch buffer. Conversion now uses one row, and successful
GPU uploads release decoded pixels while keeping the compressed source for
style/context recreation. The pilot then replaces the style to verify this
recovery path. No larger heap setting is used.

The shader is unlit. JPEG baking/resampling changes some texels, so screenshots
are visual comparison evidence, while the saved graph probes establish exact
color-formula agreement. Debug emulator runs do not establish device performance.
