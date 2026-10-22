// Run from the SDK repository root on macOS with Xcode command-line tools.
// Compile the decoder and this file with swiftc, then run the output executable.
// See the command in tool/animated_entities/ios/README.md.
// This checks CPU decoding/evaluation; Metal and Mapbox need the integration test.
import Foundation
import simd

@main struct Checks {
    static func main() throws {
        precondition(MemoryLayout<MoveySkinVertex>.stride == 64 && MemoryLayout<MoveySkinVertex>.offset(of: \.texCoord) == 48)
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tool/animated_entities/fixtures/RiggedSimple.glb"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let asset = try MoveyGLBDecoder.decode(data, cancellation: MoveyGLBCancellation())
        precondition(asset.vertices.count == 160 && asset.indices.count == 564 && asset.joints.count == 2 && asset.clips.count == 1)
        let first = asset.pose(time: 0.25, clipIndex: 0)!
        let second = asset.pose(time: 0.85, clipIndex: 0)!
        precondition(zip(first.palette, second.palette).contains { a, b in (0..<4).contains { c in simd_length(a[c] - b[c]) > 0.01 } })
        let restGlobals = MoveyRiggedAsset.globals(nodes: asset.nodes, traversal: asset.traversal, clip: nil, time: 0)
        var lo = Double.infinity, hi = -Double.infinity
        for v in asset.vertices {
            var point = SIMD4<Double>(repeating: 0)
            for component in 0..<4 { point += (restGlobals[asset.joints[Int(v.joints[component])]] * asset.inverseBindMatrices[Int(v.joints[component])] * SIMD4<Double>(v.position)) * Double(v.weights[component]) }
            point = asset.normalizedWorldToMap * point
            lo = min(lo, point.z); hi = max(hi, point.z)
        }
        precondition(abs(lo) < 1e-8 && abs(hi - 1) < 1e-8)
        func withCurves(_ curves: [MoveyRiggedAsset.Curve]) -> MoveyRiggedAsset {
            .init(vertices: asset.vertices, indices: asset.indices, nodes: asset.nodes, traversal: asset.traversal,
                  joints: asset.joints, inverseBindMatrices: asset.inverseBindMatrices,
                  clips: [.init(duration: 1, curves: curves)], skeletonFingerprint: asset.skeletonFingerprint, parts: asset.parts, textures: asset.textures,
                  normalizedWorldToMap: asset.normalizedWorldToMap)
        }
        func equal(_ a: MoveyRiggedAsset.Pose, _ b: MoveyRiggedAsset.Pose) -> Bool {
            zip(a.palette, b.palette).allSatisfy { x, y in (0..<4).allSatisfy { simd_length(x[$0] - y[$0]) < 1e-6 } }
        }
        let antipodal = withCurves([.init(node: asset.joints[1], path: "rotation", step: false,
                                         times: [0, 1], values: [SIMD4(0, 0, 0, 1), SIMD4(0, 0, 0, -1)])])
        precondition(equal(antipodal.pose(time: 0, clipIndex: 0)!, antipodal.pose(time: 0.5, clipIndex: 0)!))
        let stepped = withCurves([.init(node: asset.joints[1], path: "translation", step: true,
                                       times: [0, 1], values: [SIMD4(0, 0, 0, 0), SIMD4(1, 0, 0, 0)])])
        precondition(equal(stepped.pose(time: 0, clipIndex: 0)!, stepped.pose(time: 0.99, clipIndex: 0)!))
        precondition(!equal(stepped.pose(time: 0, clipIndex: 0)!, stepped.pose(time: 1, clipIndex: 0)!))
        func expect(_ bytes: Data, _ code: String) throws {
            do { _ = try MoveyGLBDecoder.decode(bytes, cancellation: MoveyGLBCancellation()); fatalError("Expected \(code)") }
            catch let failure as MoveyGLBFailure { precondition(failure.code == code, failure.code) }
        }
        try expect(Data([1, 2, 3]), "GLB_INVALID")
        try expect(Data(repeating: 0, count: MoveyGLBDecoder.maximumBytes + 1), "GLB_TOO_LARGE")
        let cancelled = MoveyGLBCancellation(); cancelled.cancel()
        do { _ = try MoveyGLBDecoder.decode(data, cancellation: cancelled); fatalError("Expected cancellation") }
        catch let error as MoveyGLBFailure { precondition(error.code == "LOAD_SUPERSEDED") }
        func modified(_ source: Data? = nil, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
            let data = source ?? data
            let original = [UInt8](data)
            let jsonLength = Int(UInt32(original[12]) | UInt32(original[13]) << 8 | UInt32(original[14]) << 16 | UInt32(original[15]) << 24)
            var json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + jsonLength))) as! [String: Any]
            mutate(&json)
            var encoded = try JSONSerialization.data(withJSONObject: json)
            while encoded.count % 4 != 0 { encoded.append(32) }
            let binChunk = data.subdata(in: (20 + jsonLength)..<data.count)
            var output = Data()
            func word(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { output.append(contentsOf: $0) } }
            word(0x46546c67); word(2); word(UInt32(20 + encoded.count + binChunk.count)); word(UInt32(encoded.count)); word(0x4e4f534a)
            output.append(encoded); output.append(binChunk)
            return output
        }
        let multipart = try MoveyGLBDecoder.decode(modified { root in
            var meshes = root["meshes"] as! [[String: Any]]
            let primitive = (meshes[0]["primitives"] as! [[String: Any]])[0]
            meshes[0]["primitives"] = [primitive, primitive]
            root["meshes"] = meshes
            var materials = root["materials"] as! [[String: Any]]
            materials[0]["extras"] = ["moveySkin": true]
            root["materials"] = materials
        }, cancellation: MoveyGLBCancellation())
        precondition(multipart.parts.count == 2 && multipart.vertices.count == 320 && multipart.indices.count == 1128)
        precondition(multipart.parts[0].firstIndex == 0 && multipart.parts[1].firstIndex == 564)
        precondition(multipart.parts[0].indexCount == 564 && multipart.parts[1].skin)
        precondition(multipart.indices[564] == multipart.indices[0] + 160 && multipart.joints.count == 2)
        precondition(asset.hasSameRig(as: multipart))
        let changedRig = try MoveyGLBDecoder.decode(modified { root in
            var nodes = root["nodes"] as! [[String: Any]]
            nodes[3]["name"] = "DifferentJointIdentity"
            root["nodes"] = nodes
        }, cancellation: MoveyGLBCancellation())
        precondition(!asset.hasSameRig(as: changedRig))
        try expect(modified { root in
            var meshes = root["meshes"] as! [[String: Any]]
            let primitive = (meshes[0]["primitives"] as! [[String: Any]])[0]
            meshes[0]["primitives"] = Array(repeating: primitive, count: 17)
            root["meshes"] = meshes
        }, "GLB_UNSUPPORTED")
        try expect(modified { root in
            var nodes = root["nodes"] as! [[String: Any]]
            nodes[2]["skin"] = 1
            root["nodes"] = nodes
        }, "GLB_INVALID")
        let white = MoveyCharacterPalette.linear("#FFFFFF")!
        let middle = MoveyCharacterPalette.linear("#808080")!
        precondition(white == SIMD4<Float>(1, 1, 1, 1) && abs(middle.x - 0.2158605) < 1e-6)
        precondition(MoveyCharacterPalette.linear("#000000") == SIMD4<Float>(0, 0, 0, 1))
        for invalid in ["red", "#FFF", "#GG0000", "#00000000", "0000000", "#-00001"] {
            precondition(MoveyCharacterPalette.linear(invalid) == nil)
        }
        let casesData = try Data(contentsOf: URL(fileURLWithPath: "tool/animated_entities/fixtures/customizer-tint-cases.json"))
        let referenceRoot = try JSONSerialization.jsonObject(with: casesData) as! [String: Any]
        let referenceCases = referenceRoot["cases"] as! [[String: Any]]
        func vector(_ value: Any) -> SIMD3<Float> {
            let values = value as! [NSNumber]
            return SIMD3(values[0].floatValue, values[1].floatValue, values[2].floatValue)
        }
        var maximumTintError: Float = 0
        for row in referenceCases {
            let actual = MoveyCharacterPalette.customizer(base: vector(row["baseLinear"]!), mask: vector(row["mask"]!),
                skin: vector(row["skinLinear"]!), eye: vector(row["eyeLinear"]!))
            let expected = vector(row["expectedLinear"]!)
            let difference = simd_abs(actual - expected)
            let error = max(difference.x, max(difference.y, difference.z))
            maximumTintError = max(maximumTintError, error)
            precondition(error < 0.00001, "Customizer graph mismatch \(row["name"]!): \(actual) != \(expected)")
        }
        precondition(MoveyCharacterPalette.linearComponents([0.88792324, 0.38132605, 0.1559265]) == MoveyCharacterPalette.customizerSkin)
        for invalid: Any in [[0.0, 0.2, 0.3], [Double.nan, 0.2, 0.3], [1.1, 0.2, 0.3], [true, 0.2, 0.3], [0.1, 0.2]] {
            precondition(MoveyCharacterPalette.linearComponents(invalid) == nil)
        }
        print("PASS \(referenceCases.count) saved Blender/Cycles tint graph probes; maximum linear error \(maximumTintError)")
        print("PASS multipart shared skin/index offsets, part bounds and sRGB palette transfer")
        try expect(modified { $0["extensionsRequired"] = ["KHR_draco_mesh_compression"] }, "GLB_UNSUPPORTED")
        try expect(modified { root in var nodes = root["nodes"] as! [[String: Any]]; nodes[4]["children"] = [0]; root["nodes"] = nodes }, "GLB_INVALID")
        try expect(modified { root in var views = root["bufferViews"] as! [[String: Any]]; views[0]["byteOffset"] = 999999; root["bufferViews"] = views }, "GLB_INVALID")
        try expect(modified { root in var animations = root["animations"] as! [[String: Any]]; var samplers = animations[0]["samplers"] as! [[String: Any]]; samplers[0]["interpolation"] = "CUBICSPLINE"; animations[0]["samplers"] = samplers; root["animations"] = animations }, "GLB_UNSUPPORTED")
        var clock = MoveyRiggedAnimationClock()
        clock.tick(now: 1, rate: 1, duration: 10, playing: true)
        clock.tick(now: 2, rate: 1, duration: 10, playing: true)
        precondition(clock.time == 1)
        clock.tick(now: 2, rate: 2, duration: 10, playing: true)
        precondition(clock.time == 1)
        clock.tick(now: 2.5, rate: 2, duration: 10, playing: true)
        precondition(clock.time == 2)
        clock.suspend(); clock.tick(now: 99, rate: 2, duration: 10, playing: false)
        precondition(clock.time == 2)
        clock.retime(duration: 1.5); precondition(clock.time == 0.5)
        clock.tick(now: 99, rate: 1, duration: 1.5, playing: true)
        precondition(clock.time == 0.5)
        clock.reset(); precondition(clock.time == 0)
        var tween = MoveyRiggedPlacementTween(.init(latitude: 10, longitude: 179, headingDegrees: 350), now: 0)
        tween.retarget(.init(latitude: 12, longitude: -179, headingDegrees: 10), now: 1)
        let midpoint = tween.sample(now: 1.25)
        precondition(abs(abs(midpoint.longitude) - 180) < 1e-8 && abs(midpoint.headingDegrees) < 1e-8)
        tween.setSuspended(true, now: 1.25)
        precondition(tween.sample(now: 99).latitude == midpoint.latitude)
        tween.setSuspended(false, now: 99)
        precondition(tween.sample(now: 99).latitude == midpoint.latitude)
        tween.retarget(.init(latitude: 13, longitude: -178, headingDegrees: 20), now: 99)
        precondition(tween.sample(now: 99).latitude == midpoint.latitude)
        precondition(!tween.isMoving(now: 100) && tween.sample(now: 100).latitude == 13)
        var reversal = MoveyRiggedPlacementTween(.init(latitude: 10, longitude: 20, headingDegrees: 0), now: 0)
        reversal.retarget(.init(latitude: 12, longitude: 22, headingDegrees: 180), now: 1)
        precondition(reversal.sample(now: 1).headingDegrees == 0)
        precondition(abs(reversal.sample(now: 1.1).headingDegrees) < 3)
        precondition(reversal.sample(now: 1.5).latitude == 12 && reversal.isMoving(now: 1.5))
        precondition(abs(reversal.sample(now: 1.75).headingDegrees + 90) < 1e-8)
        // A new GPS position with the same course must not restart the turn.
        reversal.retarget(.init(latitude: 13, longitude: 23, headingDegrees: 180), now: 1.5)
        precondition(abs(reversal.sample(now: 1.75).headingDegrees + 90) < 1e-8)
        reversal.setSuspended(true, now: 1.75)
        precondition(abs(reversal.sample(now: 99).headingDegrees + 90) < 1e-8)
        reversal.setSuspended(false, now: 99)
        precondition(abs(reversal.sample(now: 99).headingDegrees + 90) < 1e-8)
        precondition(abs(reversal.sample(now: 99.75).headingDegrees + 180) < 1e-8 && !reversal.isMoving(now: 99.75))
        reversal.retarget(.init(latitude: 14, longitude: 24, headingDegrees: 90), now: 100)
        let beforeRetarget = reversal.sample(now: 100.2).headingDegrees
        reversal.retarget(.init(latitude: 15, longitude: 25, headingDegrees: 0), now: 100.2)
        precondition(abs(reversal.sample(now: 100.2).headingDegrees - beforeRetarget) < 1e-8)
        print("PASS eased 180-degree turns, independent GPS/heading clocks and retarget continuity")
        var opacity = MoveyRiggedOpacityTween(0, now: 0)
        precondition(opacity.sample(now: 10) == 0 && !opacity.isAnimating(now: 10))
        opacity.retarget(1, duration: 0.22, now: 10)
        precondition(opacity.sample(now: 10) == 0 && opacity.isAnimating(now: 10))
        precondition(abs(opacity.sample(now: 10.11) - 0.5) < 1e-8)
        // Repeated targets, including an omitted/immediate duration, do not
        // restart a fade when GPS or clip updates carry the same visibility.
        opacity.retarget(1, duration: 0, now: 10.11)
        precondition(abs(opacity.sample(now: 10.11) - 0.5) < 1e-8)
        precondition(opacity.sample(now: 10.23) == 1 && !opacity.isAnimating(now: 10.23))
        opacity.retarget(0, duration: 0.22, now: 11)
        let fading = opacity.sample(now: 11.11)
        opacity.retarget(1, duration: 0.22, now: 11.11)
        precondition(abs(opacity.sample(now: 11.11) - fading) < 1e-8)
        opacity.setSuspended(true, now: 11.11)
        precondition(abs(opacity.sample(now: 99) - fading) < 1e-8)
        opacity.setSuspended(false, now: 99)
        precondition(abs(opacity.sample(now: 99) - fading) < 1e-8)
        clock.tick(now: 99.11, rate: 1, duration: 10, playing: false)
        precondition(clock.time == 0 && opacity.sample(now: 99.11) > fading)
        opacity.retarget(0, duration: 0, now: 99.11)
        precondition(opacity.sample(now: 99.11) == 0 && !opacity.isAnimating(now: 99.11))
        print("PASS hidden opacity defaults, paused-independent fade endpoints, unchanged target, reversal and background suspension")
        if CommandLine.arguments.count > 2 {
            let foxData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let fox = try MoveyGLBDecoder.decode(foxData, cancellation: MoveyGLBCancellation())
            precondition(fox.vertices.count == 1728 && fox.indices.count == 1728 && fox.joints.count == 24 && fox.clips.count == 3)
            precondition(fox.texture?.width == 1024 && fox.texture?.height == 1024 && fox.texture?.rgba.count == 4_194_304)
            precondition(fox.texture?.requiresMipmaps == true && fox.texture?.wrapS == 10497)
            precondition(fox.vertices.contains { $0.texCoord != SIMD2<Float>(0, 0) })
            for clip in 0..<3 {
                let a = fox.pose(time: 0, clipIndex: clip)!, b = fox.pose(time: fox.clips[clip].duration * 0.4, clipIndex: clip)!
                precondition(!equal(a, b))
            }
            try expect(modified(foxData) { root in
                var images = root["images"] as! [[String: Any]]; images[0]["uri"] = "https://example.invalid/texture.png"; root["images"] = images
            }, "GLB_UNSUPPORTED")
            try expect(modified(foxData) { root in
                var images = root["images"] as! [[String: Any]]; images[0]["bufferView"] = 0; root["images"] = images
            }, "GLB_INVALID")
            try expect(modified(foxData) { root in
                var samplers = root["samplers"] as! [[String: Any]]; samplers[0]["minFilter"] = 9982; root["samplers"] = samplers
            }, "GLB_UNSUPPORTED")
            let tint = try MoveyGLBDecoder.decode(modified(foxData) { root in
                var materials = root["materials"] as! [[String: Any]]
                materials[0]["extras"] = ["moveyTintMaskTexture": 0]
                root["materials"] = materials
            }, cancellation: MoveyGLBCancellation())
            precondition(tint.parts[0].textureIndex == tint.parts[0].tintMaskTextureIndex && tint.textures.count == 1)
            try expect(modified(foxData) { root in
                var materials = root["materials"] as! [[String: Any]]
                materials[0]["extras"] = ["moveyTintMaskTexture": 16]
                root["materials"] = materials
            }, "GLB_INVALID")
            print("PASS original Fox embedded PNG/UV, 24-joint GPU input, three actual animated palettes; external image, malformed image, sampler rejection")
        }
        if CommandLine.arguments.count > 3 {
            let characterData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            let character = try MoveyGLBDecoder.decode(characterData, cancellation: MoveyGLBCancellation())
            precondition(character.parts.count > 1 && character.parts.count <= 16 && character.joints.count == 57)
            precondition(character.indices.count == character.parts.reduce(0) { $0 + $1.indexCount })
            precondition(character.vertices.count <= 65536 && character.textures.count <= 16 && character.clips.count == 3)
            if character.skeletonFingerprint != nil {
                precondition(character.parts.contains { $0.skin || $0.tintMode == .customizerSkin })
                let maskIndices = Set(character.parts.compactMap { $0.tintMaskTextureIndex })
                precondition(!maskIndices.isEmpty)
                try expect(modified(characterData) { root in
                    var meshes = root["meshes"] as! [[String: Any]]
                    var materials = root["materials"] as! [[String: Any]]
                    var textures = root["textures"] as! [[String: Any]]
                    let accessors = root["accessors"] as! [[String: Any]]
                    let primitives = meshes.flatMap { $0["primitives"] as! [[String: Any]] }
                    var smallest = primitives.min { a, b in
                        let x = (a["attributes"] as! [String: Any])["POSITION"] as! Int
                        let y = (b["attributes"] as! [String: Any])["POSITION"] as! Int
                        return (accessors[x]["count"] as! Int) < (accessors[y]["count"] as! Int)
                    }!
                    var added = meshes[0]["primitives"] as! [[String: Any]]
                    // Five distinct texture indices sharing the 2048px source
                    // would allocate >64 MiB without the aggregate RGBA cap.
                    for _ in 0..<5 {
                        textures.append(textures[0])
                        var material = materials[0]
                        material.removeValue(forKey: "extras")
                        var pbr = material["pbrMetallicRoughness"] as! [String: Any]
                        pbr["baseColorTexture"] = ["index": textures.count - 1]
                        material["pbrMetallicRoughness"] = pbr
                        materials.append(material)
                        smallest["material"] = materials.count - 1
                        added.append(smallest)
                    }
                    meshes[0]["primitives"] = added
                    root["meshes"] = meshes
                    root["materials"] = materials
                    root["textures"] = textures
                }, "GLB_UNSUPPORTED")
                for index in maskIndices {
                    let rgba = [UInt8](character.textures[index].rgba)
                    precondition(stride(from: 0, to: rgba.count, by: 4).contains { rgba[$0] > 0 })
                    precondition(stride(from: 1, to: rgba.count, by: 4).contains { rgba[$0] > 0 })
                }
            }
            for clip in character.clips.indices {
                let a = character.pose(time: 0, clipIndex: clip)!, b = character.pose(time: character.clips[clip].duration * 0.4, clipIndex: clip)!
                precondition(!equal(a, b))
            }
            print("PASS real Movey V5 \(character.parts.count)-part/57-joint three-clip character, shared indexed geometry and materials")
        }
        print("PASS native placement short-arc/dateline, retarget continuity and foreground suspension")
        print("PASS RiggedSimple decode, actual pose deformation, grounded unit rest height, quaternion short arc, STEP, malformed/header/bounds/cycle/extension/interpolation/cancellation limits")
    }
}
