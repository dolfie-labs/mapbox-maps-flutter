# Upstream pin — Movey native-layer draft

| Field | Value |
| --- | --- |
| Upstream | https://github.com/mapbox/mapbox-maps-flutter |
| Baseline branch | `release/v3.33` |
| Baseline commit | `599e3f376418552f89b6c398eccd8f141e367d06` |
| User fork | https://github.com/dolfie-labs/mapbox-maps-flutter |
| Intended development branch | `codex/movey-animated-entities-v3` |
| Four Flutter package versions | `3.33.0` |
| Android Maps artifact | `com.mapbox.maps:android-ndk27:11.33.0` |
| iOS Maps SDK, Pod/SPM | `11.33.0` |
| Minimum Flutter / Dart | `3.38.1` / `3.10.0` |
| Experimental API | iOS `@_spi(Experimental) CustomLayerHost` |
| Native cube build / runtime | Android APK + iOS Simulator SPM build **PASS**; cube runtime **PASS** on Android emulator and iOS Simulator |
| glTF skeletal renderer | **IMPLEMENTED** for the bounded P0C subset; visible GPU pose A/B verified on Android emulator and iOS Simulator only |
| Home character support | Cached placement/clip updates, 500 ms native interpolation and bounded embedded base-color textures; original Fox Survey/Walk/Run verified on GLES/Metal simulators |
| Smooth representation switch | Optional hidden GPU prewarm and native opacity fades; original opacity defaults remain unchanged |

This draft was authored from the user's checked-out baseline. The generated
Pigeon schemas/bindings, original channels, package versions, web backend and
native SDK pins are unchanged. The probe uses a new optional capability and
separate map-suffixed channel. See the current
[GLTF_ANIMATION_P0.md](GLTF_ANIMATION_P0.md) and historical
[ANIMATED_ENTITIES_P0.md](ANIMATED_ENTITIES_P0.md).

The temporary draft repository's local snapshot commit is only a patch-making
baseline; it is not an upstream SHA or a published fork release. No remote
commit or production dependency pin is claimed by this document.
