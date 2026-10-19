import CoreFoundation
import Foundation
import simd

/// Deliberately bounded glTF 2.0 subset for the native P0 skinning probe.
struct MoveyGLBFailure: Error {
    let code: String
    let message: String
    static func invalid(_ message: String) -> Self { Self(code: "GLB_INVALID", message: message) }
    static func unsupported(_ message: String) -> Self { Self(code: "GLB_UNSUPPORTED", message: message) }
}

final class MoveyGLBCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw MoveyGLBFailure(code: "LOAD_SUPERSEDED", message: "The model load was superseded.") }
    }
}

struct MoveySkinVertex {
    let position: SIMD4<Float>
    let joints: SIMD4<UInt32>
    let weights: SIMD4<Float>
}

struct MoveyRiggedAsset {
    struct Node {
        let parent: Int?
        let matrix: simd_double4x4?
        let translation: SIMD3<Double>
        let rotation: SIMD4<Double>
        let scale: SIMD3<Double>
    }
    struct Curve {
        let node: Int
        let path: String
        let step: Bool
        let times: [Double]
        let values: [SIMD4<Double>]
    }
    struct Clip {
        let duration: Double
        let curves: [Curve]
    }
    struct Pose {
        let palette: [simd_float4x4]
    }
    let vertices: [MoveySkinVertex]
    let indices: [UInt32]
    let nodes: [Node]
    let traversal: [Int]
    let joints: [Int]
    let inverseBindMatrices: [simd_double4x4]
    let clips: [Clip]
    let baseColor: SIMD4<Float>
    /// Converts world-space glTF Y-up to a grounded, unit-height E/S/Up model.
    let normalizedWorldToMap: simd_double4x4

    func pose(time: Double, clipIndex: Int) -> Pose? {
        let globals = Self.globals(nodes: nodes, traversal: traversal, clip: clips[clipIndex], time: time)
        let palette = joints.enumerated().map { index, joint in
            Self.floatMatrix(globals[joint] * inverseBindMatrices[index])
        }
        guard palette.allSatisfy(Self.finite) else { return nil }
        return Pose(palette: palette)
    }

    static func globals(nodes: [Node], traversal: [Int], clip: Clip?, time: Double) -> [simd_double4x4] {
        var translations = nodes.map(\.translation)
        var rotations = nodes.map(\.rotation)
        var scales = nodes.map(\.scale)
        if let clip {
            for curve in clip.curves {
                let value = sample(curve, time: time)
                switch curve.path {
                case "translation": translations[curve.node] = SIMD3(value.x, value.y, value.z)
                case "rotation": rotations[curve.node] = value
                default: scales[curve.node] = SIMD3(value.x, value.y, value.z)
                }
            }
        }
        var globals = Array(repeating: matrix_identity_double4x4, count: nodes.count)
        for index in traversal {
            let node = nodes[index]
            let local = node.matrix ?? trs(translations[index], rotations[index], scales[index])
            globals[index] = node.parent.map { globals[$0] * local } ?? local
        }
        return globals
    }

    private static func sample(_ curve: Curve, time: Double) -> SIMD4<Double> {
        guard time > curve.times[0] else { return curve.values[0] }
        guard time < curve.times[curve.times.count - 1] else { return curve.values[curve.values.count - 1] }
        var low = 0
        var high = curve.times.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if curve.times[middle] <= time { low = middle } else { high = middle }
        }
        if curve.step { return curve.values[low] }
        let amount = (time - curve.times[low]) / (curve.times[high] - curve.times[low])
        let a = curve.values[low]
        var b = curve.values[high]
        guard curve.path == "rotation" else { return a + (b - a) * amount }
        // glTF rotations use quaternion shortest-arc spherical interpolation.
        var cosine = simd_dot(a, b)
        if cosine < 0 { b = -b; cosine = -cosine }
        if cosine > 0.9995 { return simd_normalize(a + (b - a) * amount) }
        let angle = acos(min(1, max(-1, cosine)))
        return simd_normalize((a * sin((1 - amount) * angle) + b * sin(amount * angle)) / sin(angle))
    }

    static func trs(_ translation: SIMD3<Double>, _ rotation: SIMD4<Double>, _ scale: SIMD3<Double>) -> simd_double4x4 {
        var result = simd_double4x4(simd_quatd(vector: rotation))
        result.columns.0 *= scale.x
        result.columns.1 *= scale.y
        result.columns.2 *= scale.z
        result.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
        return result
    }

    static func floatMatrix(_ matrix: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(matrix.columns.0), SIMD4<Float>(matrix.columns.1),
            SIMD4<Float>(matrix.columns.2), SIMD4<Float>(matrix.columns.3)
        ))
    }

    static func finite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }
    }
}

enum MoveyGLBDecoder {
    static let maximumBytes = 2 * 1024 * 1024

    static func decode(_ data: Data, cancellation: MoveyGLBCancellation) throws -> MoveyRiggedAsset {
        if data.count > maximumBytes { throw MoveyGLBFailure(code: "GLB_TOO_LARGE", message: "A probe GLB must be at most 2 MiB.") }
        try cancellation.check()
        guard data.count >= 20, uint32(data, 0) == 0x46546c67,
              uint32(data, 4) == 2, Int(uint32(data, 8)) == data.count else {
            throw MoveyGLBFailure.invalid("Invalid GLB 2.0 header or length.")
        }
        var offset = 12
        var jsonData: Data?
        var binary: Data?
        while offset < data.count {
            guard offset <= data.count - 8 else { throw MoveyGLBFailure.invalid("Truncated GLB chunk header.") }
            let length = Int(uint32(data, offset))
            let type = uint32(data, offset + 4)
            offset += 8
            guard length % 4 == 0, length <= data.count - offset else { throw MoveyGLBFailure.invalid("Invalid GLB chunk bounds.") }
            let chunk = data.subdata(in: offset..<(offset + length))
            if type == 0x4e4f534a {
                guard jsonData == nil, offset == 20 else { throw MoveyGLBFailure.invalid("GLB JSON must be its first and only JSON chunk.") }
                jsonData = chunk
            } else if type == 0x004e4942 {
                guard jsonData != nil, binary == nil else { throw MoveyGLBFailure.invalid("Invalid GLB binary chunk order.") }
                binary = chunk
            } else {
                throw MoveyGLBFailure.unsupported("Additional GLB chunk types are outside the probe subset.")
            }
            offset += length
        }
        guard let jsonData, let binary,
              let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MoveyGLBFailure.invalid("GLB requires a JSON object and embedded binary chunk.")
        }
        return try Parser(root: root, binary: binary, cancellation: cancellation).parse()
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> UInt32 in
            let a = UInt32(bytes[offset])
            let b = UInt32(bytes[offset + 1]) << 8
            let c = UInt32(bytes[offset + 2]) << 16
            let d = UInt32(bytes[offset + 3]) << 24
            return a | b | c | d
        }
    }

    private struct Parser {
        let root: [String: Any]
        let binary: Data
        let cancellation: MoveyGLBCancellation

        func parse() throws -> MoveyRiggedAsset {
            try cancellation.check()
            guard let asset = root["asset"] as? [String: Any], asset["version"] as? String == "2.0" else {
                throw MoveyGLBFailure.unsupported("Only glTF 2.0 is supported.")
            }
            for key in ["extensionsRequired", "extensionsUsed", "textures", "images", "samplers", "cameras"] {
                if let array = root[key] as? [Any], !array.isEmpty { throw MoveyGLBFailure.unsupported("\(key) is outside the untextured probe subset.") }
            }
            let buffers = try objects(root, "buffers", maximum: 1)
            guard buffers.count == 1, buffers[0]["uri"] == nil else { throw MoveyGLBFailure.unsupported("Only one embedded GLB buffer is supported.") }
            let byteLength = try integer(buffers[0], "byteLength", minimum: 1, maximum: binary.count)
            guard binary.count - byteLength <= 3 else { throw MoveyGLBFailure.invalid("Binary chunk length does not match its buffer.") }
            let views = try objects(root, "bufferViews", maximum: 256)
            let accessors = try objects(root, "accessors", maximum: 256)
            let reader = AccessorReader(binary: binary, byteLength: byteLength, views: views, accessors: accessors)
            try reader.validateDefinitions()
            let rawNodes = try objects(root, "nodes", maximum: 128)
            guard !rawNodes.isEmpty else { throw MoveyGLBFailure.invalid("A skinned scene requires nodes.") }
            var parents = Array<Int?>(repeating: nil, count: rawNodes.count)
            var children = Array(repeating: [Int](), count: rawNodes.count)
            for (index, node) in rawNodes.enumerated() {
                if node["extensions"] != nil || node["weights"] != nil || node["camera"] != nil {
                    throw MoveyGLBFailure.unsupported("Node extensions, morph weights and cameras are unsupported.")
                }
                if let raw = node["children"] {
                    guard let values = raw as? [Any], values.count <= 128 else { throw MoveyGLBFailure.invalid("Invalid node children.") }
                    for value in values {
                        let child = try integerValue(value, minimum: 0, maximum: rawNodes.count - 1)
                        guard child != index, parents[child] == nil, !children[index].contains(child) else {
                            throw MoveyGLBFailure.invalid("Node hierarchy has a cycle, duplicate child or multiple parents.")
                        }
                        parents[child] = index
                        children[index].append(child)
                    }
                }
            }
            var marks = Array(repeating: 0, count: rawNodes.count)
            var traversal: [Int] = []
            func visit(_ index: Int) throws {
                if marks[index] == 1 { throw MoveyGLBFailure.invalid("Node hierarchy contains a cycle.") }
                if marks[index] == 2 { return }
                marks[index] = 1
                traversal.append(index)
                for child in children[index] { try visit(child) }
                marks[index] = 2
            }
            for index in rawNodes.indices where parents[index] == nil { try visit(index) }
            guard traversal.count == rawNodes.count else { throw MoveyGLBFailure.invalid("Node hierarchy contains an unreachable cycle.") }
            let scenes = try objects(root, "scenes", maximum: 8)
            guard !scenes.isEmpty else { throw MoveyGLBFailure.invalid("A default scene is required.") }
            let sceneIndex = try optionalInteger(root, "scene", fallback: 0, minimum: 0, maximum: scenes.count - 1)
            guard let roots = scenes[sceneIndex]["nodes"] as? [Any], !roots.isEmpty else { throw MoveyGLBFailure.invalid("Scene roots are missing.") }
            var sceneNodes = Set<Int>()
            func include(_ index: Int) { sceneNodes.insert(index); children[index].forEach(include) }
            for value in roots {
                let index = try integerValue(value, minimum: 0, maximum: rawNodes.count - 1)
                guard parents[index] == nil, !sceneNodes.contains(index) else { throw MoveyGLBFailure.invalid("Scene roots must be unique hierarchy roots.") }
                include(index)
            }
            let meshes = try objects(root, "meshes", maximum: 1)
            let skins = try objects(root, "skins", maximum: 1)
            guard meshes.count == 1, skins.count == 1 else { throw MoveyGLBFailure.unsupported("The probe requires exactly one mesh and one skin.") }
            let meshNodes = rawNodes.indices.filter { rawNodes[$0]["mesh"] != nil }
            guard meshNodes.count == 1, let meshNode = meshNodes.first, sceneNodes.contains(meshNode),
                  try integer(rawNodes[meshNode], "mesh", minimum: 0, maximum: 0) == 0,
                  try integer(rawNodes[meshNode], "skin", minimum: 0, maximum: 0) == 0 else {
                throw MoveyGLBFailure.unsupported("The mesh must have a single skinned scene instance.")
            }
            for index in rawNodes.indices where index != meshNode && rawNodes[index]["skin"] != nil {
                throw MoveyGLBFailure.unsupported("Additional skin instances are unsupported.")
            }
            let nodes = try rawNodes.enumerated().map { index, raw -> MoveyRiggedAsset.Node in
                let translation = try vector(raw, "translation", count: 3, fallback: [0, 0, 0])
                let rotation = try vector(raw, "rotation", count: 4, fallback: [0, 0, 0, 1])
                let scale = try vector(raw, "scale", count: 3, fallback: [1, 1, 1])
                let q = SIMD4(rotation[0], rotation[1], rotation[2], rotation[3])
                guard simd_length(q) > 1e-12 else { throw MoveyGLBFailure.invalid("A node quaternion has zero length.") }
                var matrix: simd_double4x4?
                if raw["matrix"] != nil {
                    guard raw["translation"] == nil, raw["rotation"] == nil, raw["scale"] == nil else { throw MoveyGLBFailure.invalid("A node cannot contain both matrix and TRS.") }
                    matrix = try matrixValue(vector(raw, "matrix", count: 16, fallback: []))
                }
                return .init(parent: parents[index], matrix: matrix,
                             translation: SIMD3(translation[0], translation[1], translation[2]),
                             rotation: simd_normalize(q), scale: SIMD3(scale[0], scale[1], scale[2]))
            }
            guard let jointValues = skins[0]["joints"] as? [Any], !jointValues.isEmpty, jointValues.count <= 32 else {
                throw MoveyGLBFailure.unsupported("The skin must contain 1 to 32 joints.")
            }
            let joints = try jointValues.map { try integerValue($0, minimum: 0, maximum: nodes.count - 1) }
            guard Set(joints).count == joints.count, joints.allSatisfy(sceneNodes.contains) else { throw MoveyGLBFailure.invalid("Skin joints must be unique nodes in the selected scene.") }
            if skins[0]["skeleton"] != nil {
                let skeleton = try integer(skins[0], "skeleton", minimum: 0, maximum: nodes.count - 1)
                guard sceneNodes.contains(skeleton) else { throw MoveyGLBFailure.invalid("Skin skeleton is outside the scene.") }
            }
            guard skins[0]["extensions"] == nil else { throw MoveyGLBFailure.unsupported("Skin extensions are unsupported.") }
            let inverseBindMatrices: [simd_double4x4]
            if skins[0]["inverseBindMatrices"] != nil {
                let index = try integer(skins[0], "inverseBindMatrices", minimum: 0, maximum: accessors.count - 1)
                let values = try reader.floats(index, type: "MAT4", count: joints.count)
                inverseBindMatrices = try stride(from: 0, to: values.count, by: 16).map { try matrixValue(Array(values[$0..<($0 + 16)])) }
            } else {
                inverseBindMatrices = Array(repeating: matrix_identity_double4x4, count: joints.count)
            }
            guard meshes[0]["weights"] == nil, meshes[0]["extensions"] == nil else { throw MoveyGLBFailure.unsupported("Morph weights and mesh extensions are unsupported.") }
            let primitives = try objects(meshes[0], "primitives", maximum: 1)
            guard primitives.count == 1 else { throw MoveyGLBFailure.unsupported("The probe requires one mesh primitive.") }
            let primitive = primitives[0]
            guard try optionalInteger(primitive, "mode", fallback: 4, minimum: 0, maximum: 6) == 4,
                  primitive["targets"] == nil, primitive["extensions"] == nil else { throw MoveyGLBFailure.unsupported("Only TRIANGLES without morph targets or extensions are supported.") }
            guard let attributes = primitive["attributes"] as? [String: Any],
                  Set(attributes.keys).isSubset(of: ["POSITION", "NORMAL", "JOINTS_0", "WEIGHTS_0"]) else {
                throw MoveyGLBFailure.unsupported("The probe supports only position, normal, and one set of skin attributes.")
            }
            let positionIndex = try integer(attributes, "POSITION", minimum: 0, maximum: accessors.count - 1)
            let positions = try reader.floats(positionIndex, type: "VEC3")
            let vertexCount = positions.count / 3
            guard vertexCount > 0, vertexCount <= 65536 else { throw MoveyGLBFailure.unsupported("The vertex count exceeds the probe limit.") }
            let weights = try reader.floats(integer(attributes, "WEIGHTS_0", minimum: 0, maximum: accessors.count - 1), type: "VEC4", count: vertexCount)
            let jointIndices = try reader.unsigned(integer(attributes, "JOINTS_0", minimum: 0, maximum: accessors.count - 1), type: "VEC4", joints: true, count: vertexCount)
            if attributes["NORMAL"] != nil { _ = try reader.floats(integer(attributes, "NORMAL", minimum: 0, maximum: accessors.count - 1), type: "VEC3", count: vertexCount) }
            var vertices: [MoveySkinVertex] = []
            vertices.reserveCapacity(vertexCount)
            for index in 0..<vertexCount {
                if index % 256 == 0 { try cancellation.check() }
                let start = index * 4
                let weight = SIMD4(weights[start], weights[start + 1], weights[start + 2], weights[start + 3])
                let sum = weight.x + weight.y + weight.z + weight.w
                guard weight.x >= 0, weight.y >= 0, weight.z >= 0, weight.w >= 0,
                      sum > 1e-8, abs(sum - 1) <= 0.02,
                      (start..<(start + 4)).allSatisfy({ jointIndices[$0] < joints.count }) else {
                    throw MoveyGLBFailure.invalid("Skin weights or joint indices are invalid.")
                }
                vertices.append(.init(position: SIMD4(Float(positions[index * 3]), Float(positions[index * 3 + 1]), Float(positions[index * 3 + 2]), 1),
                                      joints: SIMD4(jointIndices[start], jointIndices[start + 1], jointIndices[start + 2], jointIndices[start + 3]),
                                      weights: SIMD4<Float>(weight / sum)))
            }
            let indices: [UInt32]
            if primitive["indices"] != nil {
                indices = try reader.unsigned(integer(primitive, "indices", minimum: 0, maximum: accessors.count - 1), type: "SCALAR", joints: false)
            } else { indices = (0..<vertexCount).map(UInt32.init) }
            guard !indices.isEmpty, indices.count <= 196608, indices.count % 3 == 0,
                  indices.allSatisfy({ $0 < vertexCount }) else { throw MoveyGLBFailure.invalid("Triangle indices are out of bounds or incomplete.") }
            let materials = try optionalObjects(root, "materials", maximum: 1)
            var color = [1.0, 1.0, 1.0, 1.0]
            if primitive["material"] != nil {
                let materialIndex = try integer(primitive, "material", minimum: 0, maximum: materials.count - 1)
                let material = materials[materialIndex]
                guard material["extensions"] == nil, material["normalTexture"] == nil, material["occlusionTexture"] == nil,
                      material["emissiveTexture"] == nil, (material["alphaMode"] as? String ?? "OPAQUE") == "OPAQUE" else {
                    throw MoveyGLBFailure.unsupported("Only opaque, untextured base-color materials are supported.")
                }
                if let pbr = material["pbrMetallicRoughness"] as? [String: Any] {
                    guard pbr["baseColorTexture"] == nil, pbr["metallicRoughnessTexture"] == nil else { throw MoveyGLBFailure.unsupported("Textures are unsupported.") }
                    color = try vector(pbr, "baseColorFactor", count: 4, fallback: color)
                }
                guard color.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { throw MoveyGLBFailure.invalid("Material base color must be in [0, 1].") }
            }
            let animations = try objects(root, "animations", maximum: 8)
            guard !animations.isEmpty else { throw MoveyGLBFailure.unsupported("The rigged probe requires an animation clip.") }
            var animationScalarBudget = 0
            let clips = try animations.map { animation -> MoveyRiggedAsset.Clip in
                guard animation["extensions"] == nil else { throw MoveyGLBFailure.unsupported("Animation extensions are unsupported.") }
                let samplers = try objects(animation, "samplers", maximum: 128)
                let channels = try objects(animation, "channels", maximum: 128)
                guard !channels.isEmpty else { throw MoveyGLBFailure.invalid("An animation clip has no channels.") }
                var targets = Set<String>()
                var duration = 0.0
                let curves = try channels.map { channel -> MoveyRiggedAsset.Curve in
                    try cancellation.check()
                    let sampler = samplers[try integer(channel, "sampler", minimum: 0, maximum: samplers.count - 1)]
                    guard let target = channel["target"] as? [String: Any], let path = target["path"] as? String,
                          ["translation", "rotation", "scale"].contains(path), channel["extensions"] == nil, target["extensions"] == nil else {
                        throw MoveyGLBFailure.unsupported("Only node TRS animation channels are supported.")
                    }
                    let node = try integer(target, "node", minimum: 0, maximum: nodes.count - 1)
                    guard nodes[node].matrix == nil, sceneNodes.contains(node), targets.insert("\(node):\(path)").inserted else {
                        throw MoveyGLBFailure.invalid("Animation targets must be unique TRS nodes in the selected scene.")
                    }
                    let interpolation = sampler["interpolation"] as? String ?? "LINEAR"
                    guard ["LINEAR", "STEP"].contains(interpolation), sampler["extensions"] == nil else { throw MoveyGLBFailure.unsupported("Only LINEAR and STEP animation interpolation are supported.") }
                    let times = try reader.floats(integer(sampler, "input", minimum: 0, maximum: accessors.count - 1), type: "SCALAR")
                    guard !times.isEmpty, times.count <= 4096, times[0] >= 0,
                          zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else { throw MoveyGLBFailure.invalid("Animation times must be nonnegative and strictly increasing.") }
                    duration = max(duration, times[times.count - 1])
                    let width = path == "rotation" ? 4 : 3
                    // Reused accessors can otherwise expand a tiny GLB into a
                    // large decoded clip graph across many channels/clips.
                    animationScalarBudget += times.count * (width + 1)
                    guard animationScalarBudget <= 65536 else {
                        throw MoveyGLBFailure.unsupported("Decoded animation samples exceed the probe limit.")
                    }
                    let rawValues = try reader.floats(integer(sampler, "output", minimum: 0, maximum: accessors.count - 1), type: width == 4 ? "VEC4" : "VEC3", count: times.count)
                    let values = try (0..<times.count).map { index -> SIMD4<Double> in
                        let start = index * width
                        let value = SIMD4(rawValues[start], rawValues[start + 1], rawValues[start + 2], width == 4 ? rawValues[start + 3] : 0)
                        if path == "rotation" {
                            guard simd_length(value) > 1e-12 else { throw MoveyGLBFailure.invalid("Animation quaternion has zero length.") }
                            return simd_normalize(value)
                        }
                        return value
                    }
                    return .init(node: node, path: path, step: interpolation == "STEP", times: times, values: values)
                }
                guard duration > 0, duration <= 3600 else { throw MoveyGLBFailure.unsupported("Animation duration is outside the probe limit.") }
                return .init(duration: duration, curves: curves)
            }
            let rest = MoveyRiggedAsset.globals(nodes: nodes, traversal: traversal, clip: nil, time: 0)
            let palette = joints.enumerated().map { rest[$0.element] * inverseBindMatrices[$0.offset] }
            var minimum = SIMD3<Double>(repeating: .infinity)
            var maximum = SIMD3<Double>(repeating: -.infinity)
            for vertex in vertices {
                let position = SIMD4<Double>(vertex.position)
                var skinned = SIMD4<Double>(repeating: 0)
                for component in 0..<4 { skinned += (palette[Int(vertex.joints[component])] * position) * Double(vertex.weights[component]) }
                guard abs(skinned.w - 1) < 0.001, (0..<4).allSatisfy({ skinned[$0].isFinite }) else { throw MoveyGLBFailure.invalid("Skin bind transform produces invalid geometry.") }
                minimum = simd_min(minimum, SIMD3(skinned.x, skinned.y, skinned.z))
                maximum = simd_max(maximum, SIMD3(skinned.x, skinned.y, skinned.z))
            }
            let height = maximum.y - minimum.y
            guard height > 1e-8, height.isFinite else { throw MoveyGLBFailure.invalid("The rest-pose model has no positive Y-up height.") }
            var normalized = matrix_identity_double4x4
            normalized.columns.0.x = 1 / height
            normalized.columns.1.y = 1 / height
            normalized.columns.2.z = 1 / height
            normalized.columns.3 = SIMD4(-(minimum.x + maximum.x) / (2 * height), -minimum.y / height, -(minimum.z + maximum.z) / (2 * height), 1)
            let yUpToMap = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
            try cancellation.check()
            return MoveyRiggedAsset(vertices: vertices, indices: indices, nodes: nodes, traversal: traversal,
                                    joints: joints, inverseBindMatrices: inverseBindMatrices, clips: clips,
                                    baseColor: SIMD4(Float(color[0]), Float(color[1]), Float(color[2]), Float(color[3])),
                                    normalizedWorldToMap: yUpToMap * normalized)
        }

        private func matrixValue(_ values: [Double]) throws -> simd_double4x4 {
            guard values.count == 16, abs(values[3]) < 1e-8, abs(values[7]) < 1e-8,
                  abs(values[11]) < 1e-8, abs(values[15] - 1) < 1e-8 else { throw MoveyGLBFailure.invalid("Transforms must be finite affine matrices.") }
            return simd_double4x4(columns: (SIMD4(values[0], values[1], values[2], values[3]), SIMD4(values[4], values[5], values[6], values[7]), SIMD4(values[8], values[9], values[10], values[11]), SIMD4(values[12], values[13], values[14], values[15])))
        }

        private func vector(_ object: [String: Any], _ key: String, count: Int, fallback: [Double]) throws -> [Double] {
            guard let value = object[key] else { return fallback }
            guard let array = value as? [Any], array.count == count else { throw MoveyGLBFailure.invalid("Invalid \(key) vector width.") }
            return try array.map {
                guard let number = $0 as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      abs(number.doubleValue) <= 1e12 else { throw MoveyGLBFailure.invalid("\(key) must contain finite bounded numbers.") }
                return number.doubleValue
            }
        }

        private func objects(_ object: [String: Any], _ key: String, maximum: Int) throws -> [[String: Any]] {
            guard let array = object[key] as? [[String: Any]], array.count <= maximum else { throw MoveyGLBFailure.unsupported("\(key) is missing or exceeds the probe limit.") }
            return array
        }
        private func optionalObjects(_ object: [String: Any], _ key: String, maximum: Int) throws -> [[String: Any]] {
            object[key] == nil ? [] : try objects(object, key, maximum: maximum)
        }
        private func integer(_ object: [String: Any], _ key: String, minimum: Int, maximum: Int) throws -> Int {
            guard let value = object[key] else { throw MoveyGLBFailure.invalid("Missing \(key).") }
            return try integerValue(value, minimum: minimum, maximum: maximum)
        }
        private func optionalInteger(_ object: [String: Any], _ key: String, fallback: Int, minimum: Int, maximum: Int) throws -> Int {
            object[key] == nil ? fallback : try integer(object, key, minimum: minimum, maximum: maximum)
        }
        private func integerValue(_ value: Any, minimum: Int, maximum: Int) throws -> Int {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.doubleValue >= Double(minimum), number.doubleValue <= Double(maximum) else { throw MoveyGLBFailure.invalid("An index or count is out of bounds.") }
            return number.intValue
        }
    }

    private struct AccessorReader {
        let binary: Data
        let byteLength: Int
        let views: [[String: Any]]
        let accessors: [[String: Any]]
        private let widths = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16]

        func validateDefinitions() throws {
            for view in views {
                guard try int(view["buffer"], fallback: nil, maximum: 0) == 0 else { throw MoveyGLBFailure.invalid("Invalid bufferView buffer.") }
                let offset = try int(view["byteOffset"], fallback: 0, maximum: byteLength)
                let length = try int(view["byteLength"], fallback: nil, maximum: byteLength)
                guard length > 0, offset <= byteLength - length, view["extensions"] == nil else { throw MoveyGLBFailure.invalid("A bufferView exceeds the embedded buffer.") }
                if view["byteStride"] != nil {
                    let stride = try int(view["byteStride"], fallback: nil, maximum: 252)
                    guard stride >= 4, stride % 4 == 0 else { throw MoveyGLBFailure.invalid("Invalid bufferView byteStride.") }
                }
            }
            for accessor in accessors {
                guard accessor["sparse"] == nil, accessor["extensions"] == nil else { throw MoveyGLBFailure.unsupported("Sparse accessors and accessor extensions are unsupported.") }
                _ = try layout(accessor)
            }
        }

        func floats(_ index: Int, type: String, count: Int? = nil) throws -> [Double] {
            let accessor = try definition(index, type: type, count: count)
            guard try int(accessor["componentType"], fallback: nil, maximum: 65535) == 5126,
                  accessor["normalized"] as? Bool != true else { throw MoveyGLBFailure.unsupported("This attribute must use unnormalized FLOAT components.") }
            let info = try layout(accessor)
            return try values(info).map { raw in
                let value = Double(Float(bitPattern: raw))
                guard value.isFinite, abs(value) <= 1e12 else { throw MoveyGLBFailure.invalid("An accessor contains nonfinite or unbounded floats.") }
                return value
            }
        }

        func unsigned(_ index: Int, type: String, joints: Bool, count: Int? = nil) throws -> [UInt32] {
            let accessor = try definition(index, type: type, count: count)
            let component = try int(accessor["componentType"], fallback: nil, maximum: 65535)
            guard (joints ? [5121, 5123] : [5121, 5123, 5125]).contains(component),
                  accessor["normalized"] as? Bool != true else { throw MoveyGLBFailure.unsupported("Unsupported unsigned index or joint component type.") }
            return values(try layout(accessor))
        }

        private struct Layout {
            let start: Int
            let count: Int
            let width: Int
            let componentBytes: Int
            let stride: Int
        }
        private func definition(_ index: Int, type: String, count: Int?) throws -> [String: Any] {
            guard accessors.indices.contains(index) else { throw MoveyGLBFailure.invalid("Accessor index is out of bounds.") }
            let accessor = accessors[index]
            guard accessor["type"] as? String == type else { throw MoveyGLBFailure.invalid("Accessor has an unexpected vector type.") }
            if let count, try int(accessor["count"], fallback: nil, maximum: 196608) != count { throw MoveyGLBFailure.invalid("Accessor counts do not match.") }
            return accessor
        }
        private func layout(_ accessor: [String: Any]) throws -> Layout {
            let viewIndex = try int(accessor["bufferView"], fallback: nil, maximum: views.count - 1)
            let view = views[viewIndex]
            guard let type = accessor["type"] as? String, let width = widths[type] else { throw MoveyGLBFailure.unsupported("Unsupported accessor vector type.") }
            let component = try int(accessor["componentType"], fallback: nil, maximum: 65535)
            let bytes: Int
            switch component {
            case 5120, 5121: bytes = 1
            case 5122, 5123: bytes = 2
            case 5125, 5126: bytes = 4
            default: throw MoveyGLBFailure.unsupported("Unsupported accessor component type.")
            }
            let count = try int(accessor["count"], fallback: nil, maximum: 196608)
            let offset = try int(accessor["byteOffset"], fallback: 0, maximum: byteLength)
            let viewOffset = try int(view["byteOffset"], fallback: 0, maximum: byteLength)
            let viewLength = try int(view["byteLength"], fallback: nil, maximum: byteLength)
            let element = width * bytes
            let stride = try int(view["byteStride"], fallback: element, maximum: 252)
            guard count > 0, stride >= element, stride % bytes == 0, offset % bytes == 0,
                  (viewOffset + offset) % bytes == 0, offset <= viewLength,
                  element <= viewLength - offset,
                  count - 1 <= (viewLength - offset - element) / stride else { throw MoveyGLBFailure.invalid("Accessor range or alignment exceeds its bufferView.") }
            return Layout(start: viewOffset + offset, count: count, width: width, componentBytes: bytes, stride: stride)
        }
        private func values(_ info: Layout) -> [UInt32] {
            binary.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt32] in
                var result: [UInt32] = []
                result.reserveCapacity(info.count * info.width)
                for index in 0..<info.count {
                    for component in 0..<info.width {
                        let start = info.start + index * info.stride + component * info.componentBytes
                        var value: UInt32 = 0
                        for byte in 0..<info.componentBytes { value |= UInt32(bytes[start + byte]) << (byte * 8) }
                        result.append(value)
                    }
                }
                return result
            }
        }
        private func int(_ value: Any?, fallback: Int?, maximum: Int) throws -> Int {
            if value == nil, let fallback { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue <= Double(maximum), number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw MoveyGLBFailure.invalid("An accessor index, offset or count is invalid.")
            }
            return number.intValue
        }
    }
}
