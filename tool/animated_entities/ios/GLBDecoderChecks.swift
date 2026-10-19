// Run from the SDK repository root on macOS with Xcode command-line tools.
// Compile the decoder and this file with swiftc, then run the output executable.
// See the command in tool/animated_entities/ios/README.md.
// This checks CPU decoding/evaluation; Metal and Mapbox need the integration test.
import Foundation
import simd

@main struct Checks {
    static func main() throws {
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
                  clips: [.init(duration: 1, curves: curves)], baseColor: asset.baseColor,
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
        func modified(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
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
        try expect(modified { $0["extensionsRequired"] = ["KHR_draco_mesh_compression"] }, "GLB_UNSUPPORTED")
        try expect(modified { root in var nodes = root["nodes"] as! [[String: Any]]; nodes[4]["children"] = [0]; root["nodes"] = nodes }, "GLB_INVALID")
        try expect(modified { root in var views = root["bufferViews"] as! [[String: Any]]; views[0]["byteOffset"] = 999999; root["bufferViews"] = views }, "GLB_INVALID")
        try expect(modified { root in var animations = root["animations"] as! [[String: Any]]; var samplers = animations[0]["samplers"] as! [[String: Any]]; samplers[0]["interpolation"] = "CUBICSPLINE"; animations[0]["samplers"] = samplers; root["animations"] = animations }, "GLB_UNSUPPORTED")
        print("PASS RiggedSimple decode, actual pose deformation, grounded unit rest height, quaternion short arc, STEP, malformed/header/bounds/cycle/extension/interpolation/cancellation limits")
    }
}
