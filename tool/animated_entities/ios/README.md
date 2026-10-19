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
