"""Structural and malformed-input tests for the actual downloaded fixture."""

import copy
import json
from pathlib import Path
import struct
import unittest

from validate_rigged_fixture import FixtureError, inspect_glb


_FIXTURE_DIR = Path(__file__).parent / "fixtures"
_ASSET = (_FIXTURE_DIR / "RiggedSimple.glb").read_bytes()
_JSON_LENGTH = struct.unpack_from("<I", _ASSET, 12)[0]
_DOCUMENT = json.loads(_ASSET[20:20 + _JSON_LENGTH])
_BIN_START = 20 + _JSON_LENGTH + 8
_BINARY = _ASSET[_BIN_START:]
_MANIFEST = json.loads((_FIXTURE_DIR / "manifest.json").read_text(encoding="utf-8"))


def _repack(document=None, binary=None):
    document = _DOCUMENT if document is None else document
    binary = _BINARY if binary is None else binary
    encoded = json.dumps(document, separators=(",", ":")).encode("utf-8")
    encoded += b" " * (-len(encoded) % 4)
    return (struct.pack("<4sII", b"glTF", 2, 28 + len(encoded) + len(binary))
            + struct.pack("<I4s", len(encoded), b"JSON") + encoded
            + struct.pack("<I4s", len(binary), b"BIN\0") + binary)


class RiggedFixtureTest(unittest.TestCase):
    def test_downloaded_bytes_match_manifest_and_real_animation(self):
        report = inspect_glb(_ASSET, _MANIFEST["sha256"])
        self.assertEqual(report["byte_length"], _MANIFEST["byte_length"])
        self.assertEqual(report["json_chunk_bytes"], 3940)
        self.assertEqual(report["bin_chunk_bytes"], 11136)
        self.assertEqual(report["mesh_count"], 1)
        self.assertEqual(report["skins"], [
            {"index": 0, "name": "Armature", "joint_count": 2, "joints": [3, 4]}])
        self.assertEqual(len(report["animations"]), 1)
        clip = report["animations"][0]
        self.assertEqual(clip["index"], 0)
        self.assertIsNone(clip["name"])
        self.assertEqual(clip["channel_count"], 3)
        self.assertEqual(clip["sampler_count"], 3)
        self.assertEqual(clip["start_seconds"], 0.04166661947965622)
        self.assertEqual(clip["end_seconds"], 2.0833330154418945)
        self.assertEqual(report["accessors"][5]["count"], 50)

    def test_sha_mismatch_rejects_a_different_asset(self):
        with self.assertRaisesRegex(FixtureError, "does not match"):
            inspect_glb(_ASSET, "0" * 64)

    def test_invalid_expected_hash_is_rejected(self):
        with self.assertRaisesRegex(FixtureError, "hexadecimal"):
            inspect_glb(_ASSET, "invalid")

    def test_non_bytes_input_is_rejected(self):
        with self.assertRaisesRegex(FixtureError, "expected bytes"):
            inspect_glb("glTF")

    def test_each_incomplete_header_is_rejected(self):
        for length in range(12):
            with self.subTest(length=length), self.assertRaisesRegex(FixtureError, "truncated header"):
                inspect_glb(_ASSET[:length])

    def test_bad_magic_and_version_are_rejected(self):
        for offset, replacement, message in ((0, b"BAD!", "magic"),
                                               (4, struct.pack("<I", 1), "version")):
            modified = bytearray(_ASSET)
            modified[offset:offset + 4] = replacement
            with self.subTest(message=message), self.assertRaisesRegex(FixtureError, message):
                inspect_glb(bytes(modified))

    def test_declared_length_detects_truncation_and_trailing_bytes(self):
        for modified in (_ASSET[:-1], _ASSET + b"extra"):
            with self.subTest(length=len(modified)), self.assertRaisesRegex(FixtureError, "declared length"):
                inspect_glb(modified)

    def test_truncated_chunk_payload_even_with_matching_file_length(self):
        modified = bytearray(_ASSET[:-4])
        struct.pack_into("<I", modified, 8, len(modified))
        with self.assertRaisesRegex(FixtureError, "truncated chunk payload"):
            inspect_glb(bytes(modified))

    def test_incomplete_trailing_chunk_header(self):
        modified = bytearray(_ASSET + b"xxxx")
        struct.pack_into("<I", modified, 8, len(modified))
        with self.assertRaisesRegex(FixtureError, "truncated chunk header"):
            inspect_glb(bytes(modified))

    def test_unaligned_chunk_length(self):
        modified = bytearray(_ASSET)
        struct.pack_into("<I", modified, 12, _JSON_LENGTH + 1)
        with self.assertRaisesRegex(FixtureError, "aligned"):
            inspect_glb(bytes(modified))

    def test_wrong_chunk_order(self):
        modified = bytearray(_ASSET)
        modified[16:20] = b"BIN\0"
        with self.assertRaisesRegex(FixtureError, "JSON then BIN"):
            inspect_glb(bytes(modified))

    def test_invalid_json_encoding_and_syntax(self):
        for replacement in (b"\xff", b"!"):
            modified = bytearray(_ASSET)
            modified[20:21] = replacement
            with self.subTest(replacement=replacement), self.assertRaisesRegex(FixtureError, "UTF-8 JSON"):
                inspect_glb(bytes(modified))

    def test_external_buffer_uri_is_rejected(self):
        document = copy.deepcopy(_DOCUMENT)
        document["buffers"][0]["uri"] = "https://example.invalid/model.bin"
        with self.assertRaisesRegex(FixtureError, "external URI"):
            inspect_glb(_repack(document))

    def test_buffer_view_cannot_reference_bytes_past_buffer(self):
        document = copy.deepcopy(_DOCUMENT)
        document["bufferViews"][0]["byteLength"] = len(_BINARY) + 4
        with self.assertRaisesRegex(FixtureError, "outside buffer"):
            inspect_glb(_repack(document))

    def test_accessor_cannot_read_past_view(self):
        document = copy.deepcopy(_DOCUMENT)
        document["accessors"][5]["count"] += 1
        with self.assertRaisesRegex(FixtureError, "outside bufferView"):
            inspect_glb(_repack(document))

    def test_accessor_bounds_are_checked_against_binary_values(self):
        document = copy.deepcopy(_DOCUMENT)
        document["accessors"][5]["max"] = [100]
        with self.assertRaisesRegex(FixtureError, "declared max differs"):
            inspect_glb(_repack(document))

    def test_accessor_reference_is_range_checked(self):
        document = copy.deepcopy(_DOCUMENT)
        document["accessors"][0]["bufferView"] = len(document["bufferViews"])
        with self.assertRaisesRegex(FixtureError, "index outside"):
            inspect_glb(_repack(document))

    def test_joint_node_reference_is_range_checked(self):
        document = copy.deepcopy(_DOCUMENT)
        document["skins"][0]["joints"][0] = len(document["nodes"])
        with self.assertRaisesRegex(FixtureError, "skin joint: index outside"):
            inspect_glb(_repack(document))

    def test_channel_sampler_is_range_checked(self):
        document = copy.deepcopy(_DOCUMENT)
        document["animations"][0]["channels"][0]["sampler"] = 100
        with self.assertRaisesRegex(FixtureError, "channel sampler: index outside"):
            inspect_glb(_repack(document))

    def test_duplicate_binary_keyframe_times_are_rejected(self):
        document = copy.deepcopy(_DOCUMENT)
        accessor = document["accessors"][5]
        accessor.pop("min")
        accessor.pop("max")
        start = (document["bufferViews"][accessor["bufferView"]].get("byteOffset", 0)
                 + accessor.get("byteOffset", 0))
        binary = bytearray(_BINARY)
        binary[start + 4:start + 8] = binary[start:start + 4]
        with self.assertRaisesRegex(FixtureError, "strictly increasing"):
            inspect_glb(_repack(document, bytes(binary)))

    def test_nonfinite_binary_float_is_rejected(self):
        accessor = _DOCUMENT["accessors"][5]
        start = (_DOCUMENT["bufferViews"][accessor["bufferView"]].get("byteOffset", 0)
                 + accessor.get("byteOffset", 0))
        binary = bytearray(_BINARY)
        struct.pack_into("<f", binary, start, float("nan"))
        with self.assertRaisesRegex(FixtureError, "non-finite data"):
            inspect_glb(_repack(binary=bytes(binary)))

    def test_malformed_children_array_is_explicit_error(self):
        document = copy.deepcopy(_DOCUMENT)
        document["nodes"][0]["children"] = None
        with self.assertRaisesRegex(FixtureError, "children: expected array"):
            inspect_glb(_repack(document))


if __name__ == "__main__":
    unittest.main()
