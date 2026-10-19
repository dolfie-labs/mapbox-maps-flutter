import Foundation
import Metal
@_spi(Experimental) import MapboxMaps
import QuartzCore
import simd

struct MoveyRiggedConfiguration {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double
    let heightMeters: Double
    let headingDegrees: Double
    let clipIndex: Int
    let playbackRate: Double
}

/// The CPU asset crosses threads as an immutable snapshot. Metal resource
/// creation and destruction stay on the Mapbox custom-layer render callbacks.
final class MoveyRiggedModelRenderer: NSObject, CustomLayerHost {
    struct Diagnostics {
        let ready: Bool
        let renderedFrames: Int
        let poseRevision: Int
        let animationTimeSeconds: Double
        let vertexCount: Int
        let jointCount: Int
        let clipCount: Int
        let clipIndex: Int
        let lastErrorCode: String?
    }
    private let lock = NSLock()
    private var asset: MoveyRiggedAsset?
    private var configuration: MoveyRiggedConfiguration?
    private var generation = 0
    private var ready = false
    private var paused = true
    private var renderedFrames = 0
    private var poseRevision = 0
    private var measuredPalette: [simd_float4x4]?
    private var animationTime = 0.0
    private var lastFrameTime: CFTimeInterval?
    private var lastErrorCode: String?
    private var device: MTLDevice?
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var uploadedGeneration = -1

    func configure(asset: MoveyRiggedAsset, configuration: MoveyRiggedConfiguration) {
        lock.lock()
        self.asset = asset
        self.configuration = configuration
        generation += 1
        ready = false
        renderedFrames = 0
        poseRevision = 0
        measuredPalette = nil
        animationTime = 0
        lastFrameTime = nil
        lastErrorCode = nil
        lock.unlock()
    }

    func detach() {
        lock.lock()
        asset = nil
        configuration = nil
        generation += 1
        ready = false
        paused = true
        lastFrameTime = nil
        lock.unlock()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        if paused != value { lastFrameTime = nil }
        paused = value
        lock.unlock()
    }

    func recordError(_ code: String) {
        lock.lock(); lastErrorCode = code; lock.unlock()
    }

    func diagnostics() -> Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return Diagnostics(ready: ready, renderedFrames: renderedFrames, poseRevision: poseRevision,
                           animationTimeSeconds: animationTime, vertexCount: asset?.vertices.count ?? 0,
                           jointCount: asset?.joints.count ?? 0, clipCount: asset?.clips.count ?? 0,
                           clipIndex: configuration?.clipIndex ?? 0, lastErrorCode: lastErrorCode)
    }

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        releaseGPUResources()
        guard let color = MTLPixelFormat(rawValue: colorPixelFormat), color != .invalid,
              let depth = MTLPixelFormat(rawValue: depthStencilPixelFormat) else { recordError("METAL_PIXEL_FORMAT_UNSUPPORTED"); return }
        do {
            let library = try metalDevice.makeLibrary(source: Self.shader, options: nil)
            guard let vertex = library.makeFunction(name: "moveySkinVertex"),
                  let fragment = library.makeFunction(name: "moveySkinFragment") else { recordError("METAL_SHADER_UNAVAILABLE"); return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Movey P0 GLB GPU skinning"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = color
            descriptor.depthAttachmentPixelFormat = depth
            if depth == .depth32Float_stencil8 { descriptor.stencilAttachmentPixelFormat = depth }
            let newPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .lessEqual
            guard let newDepthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor) else { recordError("METAL_DEPTH_STATE_UNAVAILABLE"); return }
            device = metalDevice
            pipeline = newPipeline
            depthState = newDepthState
        } catch { recordError("METAL_PIPELINE_UNAVAILABLE") }
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let device, let pipeline, let depthState else { return }
        lock.lock()
        guard let asset, let configuration, lastErrorCode == nil else { lock.unlock(); return }
        let snapshotGeneration = generation
        let now = CACurrentMediaTime()
        if !paused && configuration.playbackRate > 0 {
            if let previous = lastFrameTime {
                let advance = max(0, now - previous) * configuration.playbackRate
                if advance > 0 {
                    animationTime = (animationTime + advance).truncatingRemainder(dividingBy: asset.clips[configuration.clipIndex].duration)
                }
            }
            lastFrameTime = now
        } else { lastFrameTime = nil }
        let time = animationTime
        lock.unlock()

        if uploadedGeneration != snapshotGeneration {
            let newVertices = asset.vertices.withUnsafeBufferPointer { values -> MTLBuffer? in
                guard let base = values.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: values.count * MemoryLayout<MoveySkinVertex>.stride, options: [])
            }
            let newIndices = asset.indices.withUnsafeBufferPointer { values -> MTLBuffer? in
                guard let base = values.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: values.count * MemoryLayout<UInt32>.stride, options: [])
            }
            guard let newVertices, let newIndices else { recordError("METAL_BUFFER_UNAVAILABLE"); return }
            vertexBuffer = newVertices
            indexBuffer = newIndices
            uploadedGeneration = snapshotGeneration
            lock.lock()
            if generation == snapshotGeneration { ready = true }
            lock.unlock()
        }
        guard let vertices = vertexBuffer, let indices = indexBuffer,
              let pose = asset.pose(time: time, clipIndex: configuration.clipIndex),
              var matrix = MoveyGeographicMatrix.make(parameters, latitude: configuration.latitude, longitude: configuration.longitude,
                                                       altitudeMeters: configuration.altitudeMeters, sizeMeters: configuration.heightMeters,
                                                       headingDegrees: configuration.headingDegrees, local: asset.normalizedWorldToMap) else {
            recordError("INVALID_TRANSFORM"); return
        }
        lock.lock()
        if generation == snapshotGeneration {
            if let previous = measuredPalette, zip(previous, pose.palette).contains(where: { a, b in
                (0..<4).contains { column in (0..<4).contains { abs(a[column][$0] - b[column][$0]) > 1e-7 } }
            }) { poseRevision += 1 }
            measuredPalette = pose.palette
        }
        lock.unlock()
        guard let texture = mtlRenderPassDescriptor.colorAttachments[0].texture,
              let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else { recordError("METAL_ENCODER_UNAVAILABLE"); return }
        encoder.label = "Movey P0 skinned GLB in Mapbox pass"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        pose.palette.withUnsafeBufferPointer { values in
            if let base = values.baseAddress { encoder.setVertexBytes(base, length: values.count * MemoryLayout<simd_float4x4>.stride, index: 2) }
        }
        var color = asset.baseColor
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: asset.indices.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        encoder.endEncoding()
        // Mapbox owns submission, presentation and the render target.
        lock.lock()
        if generation == snapshotGeneration { renderedFrames += 1 }
        lock.unlock()
    }

    func renderingWillEnd() { releaseGPUResources() }

    private func releaseGPUResources() {
        device = nil
        pipeline = nil
        depthState = nil
        vertexBuffer = nil
        indexBuffer = nil
        uploadedGeneration = -1
        lock.lock(); ready = false; lastFrameTime = nil; lock.unlock()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct SkinVertex { float4 position; uint4 joints; float4 weights; };
    struct SkinOutput { float4 position [[position]]; };
    vertex SkinOutput moveySkinVertex(uint id [[vertex_id]], constant SkinVertex *vertices [[buffer(0)]],
        constant float4x4 &mvp [[buffer(1)]], constant float4x4 *jointWorldInverseBind [[buffer(2)]]) {
        SkinVertex v = vertices[id];
        float4 world = (jointWorldInverseBind[v.joints.x] * v.position) * v.weights.x
                     + (jointWorldInverseBind[v.joints.y] * v.position) * v.weights.y
                     + (jointWorldInverseBind[v.joints.z] * v.position) * v.weights.z
                     + (jointWorldInverseBind[v.joints.w] * v.position) * v.weights.w;
        SkinOutput output; output.position = mvp * world; return output;
    }
    fragment float4 moveySkinFragment(SkinOutput input [[stage_in]], constant float4 &baseColor [[buffer(0)]]) { return baseColor; }
    """
}

/// Double-precision geographic composition is shared with the proven cube.
enum MoveyGeographicMatrix {
    static func make(_ parameters: CustomLayerRenderParameters, latitude: Double, longitude: Double,
                     altitudeMeters: Double, sizeMeters: Double, headingDegrees: Double,
                     local: simd_double4x4 = matrix_identity_double4x4) -> simd_float4x4? {
        let mercator = MapboxMaps.Projection.latLngToMercatorXY(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let worldSize = MapboxMaps.Projection.worldSize(scale: pow(2, parameters.zoom))
        let pixelsPerMeter = 1 / MapboxMaps.Projection.metersPerPoint(for: latitude, zoom: parameters.zoom)
        let heightScale = MapboxMaps.Projection.getLatitudeScale(parameters.latitude) / MapboxMaps.Projection.getLatitudeScale(latitude)
        var translation = matrix_identity_double4x4
        translation.columns.3 = SIMD4(mercator.x * worldSize, mercator.y * worldSize, altitudeMeters * heightScale, 1)
        var scale = matrix_identity_double4x4
        scale.columns.0.x = sizeMeters * pixelsPerMeter
        scale.columns.1.y = sizeMeters * pixelsPerMeter
        scale.columns.2.z = sizeMeters * heightScale
        let angle = headingDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        let rotation = simd_double4x4(columns: (SIMD4(cos(angle), sin(angle), 0, 0), SIMD4(-sin(angle), cos(angle), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        let model = translation * scale * rotation * local
        let numbers = (0..<4).flatMap { column in (0..<4).map { NSNumber(value: model[column][$0]) } }
        guard numbers.allSatisfy({ $0.doubleValue.isFinite }),
              let converted = parameters.projection.convertMercatorModelMatrix(forMatrix: numbers, ignoreDistortion: false),
              let world = doubleMatrix(converted), let projection = doubleMatrix(parameters.projectionMatrix) else { return nil }
        let result = MoveyRiggedAsset.floatMatrix(projection * world)
        return MoveyRiggedAsset.finite(result) ? result : nil
    }

    private static func doubleMatrix(_ numbers: [NSNumber]) -> simd_double4x4? {
        guard numbers.count == 16, numbers.allSatisfy({ $0.doubleValue.isFinite }) else { return nil }
        let columns = (0..<4).map { column in SIMD4<Double>(numbers[column * 4].doubleValue, numbers[column * 4 + 1].doubleValue, numbers[column * 4 + 2].doubleValue, numbers[column * 4 + 3].doubleValue) }
        return simd_double4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
    }
}
