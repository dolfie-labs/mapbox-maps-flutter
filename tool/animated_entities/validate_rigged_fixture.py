#!/usr/bin/env python3
"""Inspect the self-contained, uncompressed RiggedSimple GLB test fixture.

This is a deliberately small fixture validator, not a general glTF validator.
It supports one embedded buffer, dense scalar/vector/MAT4 accessors, and linear
or step node animations. It does not establish native renderer compatibility.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys


class FixtureError(ValueError):
    """The asset is invalid or outside this validator's supported subset."""


_COMPONENTS = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
               5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
_WIDTHS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise FixtureError(message)


def _integer(value: object, label: str, minimum: int = 0) -> int:
    _require(type(value) is int and value >= minimum, f"{label}: invalid integer")
    return value


def _object(value: object, label: str) -> dict:
    _require(isinstance(value, dict), f"{label}: expected object")
    return value


def _array(value: object, label: str) -> list:
    _require(isinstance(value, list) and bool(value), f"{label}: expected nonempty array")
    return value


def _index(value: object, entries: list, label: str) -> int:
    result = _integer(value, label)
    _require(result < len(entries), f"{label}: index outside array")
    return result


def _reject_constant(value: str) -> None:
    raise FixtureError(f"JSON: non-finite number {value}")


def inspect_glb(data: bytes, expected_sha256: str | None = None) -> dict:
    """Return facts decoded from the actual GLB bytes, or raise FixtureError."""
    _require(isinstance(data, bytes), "GLB: expected bytes")
    digest = hashlib.sha256(data).hexdigest()
    if expected_sha256 is not None:
        _require(isinstance(expected_sha256, str) and len(expected_sha256) == 64
                 and all(c in "0123456789abcdef" for c in expected_sha256),
                 "SHA256: expected 64 lowercase hexadecimal characters")
        _require(digest == expected_sha256, "SHA256: fixture does not match manifest")
    _require(len(data) >= 12, "GLB: truncated header")
    magic, version, total = struct.unpack_from("<4sII", data)
    _require(magic == b"glTF", "GLB: invalid magic")
    _require(version == 2, "GLB: expected version 2")
    _require(total == len(data), "GLB: declared length differs from file length")

    chunks = []
    offset = 12
    while offset < len(data):
        _require(offset + 8 <= len(data), "GLB: truncated chunk header")
        length, kind = struct.unpack_from("<I4s", data, offset)
        _require(length > 0 and length % 4 == 0, "GLB: chunk length must be positive and aligned")
        end = offset + 8 + length
        _require(end <= len(data), "GLB: truncated chunk payload")
        chunks.append((kind, data[offset + 8:end]))
        offset = end
    _require([kind for kind, _ in chunks] == [b"JSON", b"BIN\0"],
             "GLB: supported fixture requires JSON then BIN chunks only")
    try:
        document = json.loads(chunks[0][1].decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FixtureError("GLB: invalid UTF-8 JSON chunk") from error
    document = _object(document, "glTF")
    asset = _object(document.get("asset"), "asset")
    _require(asset.get("version") == "2.0", "asset: expected glTF 2.0")
    _require(not document.get("extensionsRequired") and not document.get("extensionsUsed"),
             "glTF: extensions are outside the fixture subset")
    _require(not document.get("images"), "glTF: images are outside the fixture subset")
    buffers = _array(document.get("buffers"), "buffers")
    _require(len(buffers) == 1, "buffers: expected one embedded buffer")
    buffer = _object(buffers[0], "buffer 0")
    _require("uri" not in buffer, "buffer 0: external URI is unsupported")
    buffer_length = _integer(buffer.get("byteLength"), "buffer byteLength", 1)
    binary = chunks[1][1]
    _require(buffer_length <= len(binary) <= buffer_length + 3, "buffer: invalid BIN length or padding")
    _require(not any(binary[buffer_length:]), "buffer: BIN padding must be zero")

    views = _array(document.get("bufferViews"), "bufferViews")
    for number, value in enumerate(views):
        view = _object(value, f"bufferView {number}")
        _require(view.get("buffer") == 0 and type(view.get("buffer")) is int,
                 f"bufferView {number}: expected buffer 0")
        start = _integer(view.get("byteOffset", 0), "bufferView byteOffset")
        length = _integer(view.get("byteLength"), "bufferView byteLength", 1)
        _require(start + length <= buffer_length, f"bufferView {number}: outside buffer")
        if "byteStride" in view:
            stride = _integer(view["byteStride"], "bufferView byteStride", 4)
            _require(stride <= 252 and stride % 4 == 0, "bufferView: invalid byteStride")

    accessors = _array(document.get("accessors"), "accessors")
    decoded = []
    bounds = []
    for number, value in enumerate(accessors):
        accessor = _object(value, f"accessor {number}")
        _require("sparse" not in accessor, "accessor: sparse data is unsupported")
        component = _integer(accessor.get("componentType"), "accessor componentType")
        _require(component in _COMPONENTS, "accessor: unsupported component type")
        shape = accessor.get("type")
        _require(isinstance(shape, str) and shape in _WIDTHS, "accessor: unsupported shape")
        width = _WIDTHS[shape]
        code, size = _COMPONENTS[component]
        count = _integer(accessor.get("count"), "accessor count", 1)
        view = views[_index(accessor.get("bufferView"), views, "accessor bufferView")]
        relative = _integer(accessor.get("byteOffset", 0), "accessor byteOffset")
        start = view.get("byteOffset", 0) + relative
        stride = view.get("byteStride", width * size)
        _require(relative % size == 0 and start % size == 0, "accessor: unaligned component data")
        _require(stride >= width * size and stride % size == 0, "accessor: invalid stride")
        end = relative + (count - 1) * stride + width * size
        _require(end <= view["byteLength"], f"accessor {number}: outside bufferView")
        rows = [struct.unpack_from("<" + code * width, binary, start + i * stride)
                for i in range(count)]
        _require(all(math.isfinite(v) for row in rows for v in row), "accessor: non-finite data")
        actual_min = [min(row[column] for row in rows) for column in range(width)]
        actual_max = [max(row[column] for row in rows) for column in range(width)]
        for key, actual in (("min", actual_min), ("max", actual_max)):
            if key in accessor:
                declared = accessor[key]
                _require(isinstance(declared, list) and len(declared) == width,
                         f"accessor {number}: invalid {key} shape")
                _require(all(type(v) in (int, float) and math.isfinite(v)
                             and math.isclose(v, a, rel_tol=1e-6, abs_tol=1e-7)
                             for v, a in zip(declared, actual)),
                         f"accessor {number}: declared {key} differs from binary data")
        decoded.append(rows)
        bounds.append({"index": number, "count": count, "type": shape,
                       "component_type": component, "min": actual_min, "max": actual_max})

    nodes = _array(document.get("nodes"), "nodes")
    for value in nodes:
        node = _object(value, "node")
        children = node.get("children", [])
        _require(isinstance(children, list), "node children: expected array")
        for child in children:
            _index(child, nodes, "node child")
    meshes = _array(document.get("meshes"), "meshes")
    skins = _array(document.get("skins"), "skins")
    skin_report = []
    for number, value in enumerate(skins):
        skin = _object(value, f"skin {number}")
        joints = _array(skin.get("joints"), "skin joints")
        for joint in joints:
            _index(joint, nodes, "skin joint")
        _require(len(set(joints)) == len(joints), "skin: duplicate joints")
        if "skeleton" in skin:
            _index(skin["skeleton"], nodes, "skin skeleton")
        matrix = accessors[_index(skin.get("inverseBindMatrices"), accessors, "inverseBindMatrices")]
        _require(matrix["type"] == "MAT4" and matrix["componentType"] == 5126
                 and matrix["count"] >= len(joints), "skin: invalid inverse bind matrices")
        skin_report.append({"index": number, "name": skin.get("name"),
                            "joint_count": len(joints), "joints": joints})
    for node in nodes:
        if "mesh" in node:
            _index(node["mesh"], meshes, "node mesh")
        if "skin" in node:
            _require("mesh" in node, "node: skin requires mesh")
            skin = skins[_index(node["skin"], skins, "node skin")]
            primitives = _array(_object(meshes[node["mesh"]], "mesh").get("primitives"), "primitives")
            for primitive in primitives:
                attributes = _object(_object(primitive, "primitive").get("attributes"), "attributes")
                joint_index = _index(attributes.get("JOINTS_0"), accessors, "JOINTS_0")
                weight_index = _index(attributes.get("WEIGHTS_0"), accessors, "WEIGHTS_0")
                position = accessors[_index(attributes.get("POSITION"), accessors, "POSITION")]
                _require(accessors[joint_index]["type"] == "VEC4"
                         and accessors[joint_index]["componentType"] in (5121, 5123),
                         "JOINTS_0: invalid type")
                _require(accessors[weight_index]["type"] == "VEC4"
                         and accessors[weight_index]["componentType"] == 5126,
                         "WEIGHTS_0: expected float VEC4")
                _require(accessors[joint_index]["count"] == accessors[weight_index]["count"]
                         == position["count"], "skin attributes: vertex count mismatch")
                _require(all(0 <= joint < len(skin["joints"])
                             for row in decoded[joint_index] for joint in row),
                         "JOINTS_0: joint outside skin")
                _require(all(0 <= weight <= 1 for row in decoded[weight_index] for weight in row),
                         "WEIGHTS_0: weight outside [0, 1]")

    animations = _array(document.get("animations"), "animations")
    animation_report = []
    for number, value in enumerate(animations):
        animation = _object(value, f"animation {number}")
        samplers = _array(animation.get("samplers"), "animation samplers")
        channels = _array(animation.get("channels"), "animation channels")
        times = []
        for sampler_value in samplers:
            sampler = _object(sampler_value, "animation sampler")
            input_index = _index(sampler.get("input"), accessors, "animation input")
            output_index = _index(sampler.get("output"), accessors, "animation output")
            source, output = accessors[input_index], accessors[output_index]
            _require(source["type"] == "SCALAR" and source["componentType"] == 5126,
                     "animation input: expected float SCALAR")
            _require(sampler.get("interpolation", "LINEAR") in ("LINEAR", "STEP"),
                     "animation: interpolation outside fixture subset")
            _require(source["count"] == output["count"], "animation: input/output count mismatch")
            timeline = [row[0] for row in decoded[input_index]]
            _require(timeline[0] >= 0 and all(a < b for a, b in zip(timeline, timeline[1:])),
                     "animation input: times must be nonnegative and strictly increasing")
            times.extend(timeline)
        for channel_value in channels:
            channel = _object(channel_value, "animation channel")
            sampler = samplers[_index(channel.get("sampler"), samplers, "channel sampler")]
            target = _object(channel.get("target"), "channel target")
            target_node = nodes[_index(target.get("node"), nodes, "channel target node")]
            _require("matrix" not in target_node, "animation: matrix target unsupported")
            path = target.get("path")
            _require(path in ("translation", "rotation", "scale"), "animation: unsupported target path")
            output = accessors[sampler["output"]]
            _require(output["componentType"] == 5126
                     and output["type"] == ("VEC4" if path == "rotation" else "VEC3"),
                     "animation output: invalid transform type")
        animation_report.append({"index": number, "name": animation.get("name"),
                                 "channel_count": len(channels), "sampler_count": len(samplers),
                                 "start_seconds": min(times), "end_seconds": max(times),
                                 "sample_span_seconds": max(times) - min(times)})
    return {"byte_length": len(data), "sha256": digest,
            "glb_version": version, "json_chunk_bytes": len(chunks[0][1]),
            "bin_chunk_bytes": len(binary), "mesh_count": len(meshes),
            "skins": skin_report, "animations": animation_report, "accessors": bounds}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", type=Path,
                        default=Path(__file__).parent / "fixtures" / "RiggedSimple.glb")
    parser.add_argument("--manifest", type=Path,
                        help="Verify SHA256 and byte length against fixture manifest")
    arguments = parser.parse_args()
    try:
        manifest = None
        if arguments.manifest is not None:
            manifest = _object(json.loads(arguments.manifest.read_text(encoding="utf-8")), "manifest")
            expected = manifest.get("sha256")
            _require(isinstance(expected, str), "manifest: missing SHA256")
        else:
            expected = None
        report = inspect_glb(arguments.path.read_bytes(), expected)
        if manifest is not None:
            _require(report["byte_length"] == manifest.get("byte_length"), "manifest: byte length differs")
        print(json.dumps(report, indent=2, allow_nan=False))
    except (FixtureError, OSError, json.JSONDecodeError) as error:
        print(f"Fixture validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
