# Free animated skeleton fixture

`fixtures/RiggedSimple.glb` is the unchanged **Rigged Simple** sample from
KhronosGroup/glTF-Sample-Assets, pinned to commit
`edc7c9e67c639d230715049ee31f9a96a6babbbe`. Its 15,104-byte payload contains one
mesh, one skin with two joints and one **unnamed** animation at index `0`.
The animation drives translation, rotation and scale. Do not invent an `idle`,
`walk` or other named clip for this fixture.

This fixture is staged beside the isolated fork's native P0 cube work. It is not
registered as a Flutter asset and is not loaded by the current cube probe. The
validator establishes file integrity and the listed GLB structure; native model
loading, skeletal playback, map anchoring and rendering have not been verified.

## Attribution and provenance

**Rigged Simple, © 2017 Cesium. Creative Commons Attribution 4.0 International.
Cesium for Everything.**

- [CC BY 4.0 legal terms](https://creativecommons.org/licenses/by/4.0/legalcode)
- [Pinned upstream README and attribution](https://github.com/KhronosGroup/glTF-Sample-Assets/blob/edc7c9e67c639d230715049ee31f9a96a6babbbe/Models/RiggedSimple/README.md)
- [Pinned GLB download](https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/edc7c9e67c639d230715049ee31f9a96a6babbbe/Models/RiggedSimple/glTF-Binary/RiggedSimple.glb)

The original notice is retained in `fixtures/UPSTREAM_README.md`; precise source,
hash, size, license and observations are in `fixtures/manifest.json`. The GLB has
no modifications. Preserve this attribution and license link when distributing
the fixture, and identify any later changes. This asset is CC BY 4.0, not CC0.

## Validate locally

From the fork directory, using Python 3.10 or newer and no third-party packages:

```sh
python3 tool/animated_entities/validate_rigged_fixture.py --manifest tool/animated_entities/fixtures/manifest.json
python3 -m unittest discover -s tool/animated_entities -p 'test_*.py' -v
```

The first command checks the exact SHA256 and size and prints facts read from the
actual GLB JSON and binary chunks, including decoded accessor bounds and animation
time samples. Input samples begin at `0.04166661947965622` seconds and end at
`2.0833330154418945` seconds; their span is `2.0416663959622383` seconds. These are
file observations, not a measured native playback duration.

The validator intentionally supports this simple fixture subset: one embedded
buffer, no extensions or images, dense scalar/vector/MAT4 accessors, float skin
weights and linear/step node transform animations. It rejects unsupported input
explicitly. It is not a complete glTF conformance validator or renderer.
