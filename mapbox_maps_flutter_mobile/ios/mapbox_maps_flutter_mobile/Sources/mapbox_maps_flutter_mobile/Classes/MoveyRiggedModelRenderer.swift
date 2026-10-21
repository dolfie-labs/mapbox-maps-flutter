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
    let opacity: Double
    let skinColor: SIMD4<Float>
    let eyeColor: SIMD4<Float>
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
        let opacity: Double
        let targetOpacity: Double
        let isOpacityAnimating: Bool
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
    private var clock = MoveyRiggedAnimationClock()
    private var placement: MoveyRiggedPlacementTween?
    private var opacity = MoveyRiggedOpacityTween(1, now: 0)
    private var foreground = true
    private var lastErrorCode: String?
    private var device: MTLDevice?
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var transparentDepthState: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var textures: [(MTLTexture, MTLSamplerState)] = []
    private var whiteTexture: (MTLTexture, MTLSamplerState)?
    private var blackTexture: (MTLTexture, MTLSamplerState)?
    private var uploadedGeneration = -1

    func configure(asset: MoveyRiggedAsset, configuration: MoveyRiggedConfiguration) {
        lock.lock()
        advanceClock(now: CACurrentMediaTime())
        let retainPhase = self.configuration?.clipIndex == configuration.clipIndex && self.asset?.hasSameRig(as: asset) == true
        self.asset = asset
        self.configuration = configuration
        generation += 1
        ready = false
        renderedFrames = 0
        poseRevision = 0
        measuredPalette = nil
        if retainPhase { clock.retime(duration: asset.clips[configuration.clipIndex].duration) }
        else { clock.reset() }
        opacity = MoveyRiggedOpacityTween(configuration.opacity, now: CACurrentMediaTime())
        opacity.setSuspended(!foreground, now: CACurrentMediaTime())
        var tween = MoveyRiggedPlacementTween(.init(latitude: configuration.latitude, longitude: configuration.longitude,
                                                   headingDegrees: configuration.headingDegrees), now: CACurrentMediaTime())
        tween.setSuspended(!foreground, now: CACurrentMediaTime())
        placement = tween
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
        clock.suspend()
        placement = nil
        opacity = MoveyRiggedOpacityTween(0, now: CACurrentMediaTime())
        lock.unlock()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        if paused != value {
            advanceClock(now: CACurrentMediaTime())
            clock.suspend()
        }
        paused = value
        lock.unlock()
    }

    func setForeground(_ value: Bool) {
        lock.lock()
        placement?.setSuspended(!value, now: CACurrentMediaTime())
        opacity.setSuspended(!value, now: CACurrentMediaTime())
        foreground = value
        lock.unlock()
    }

    var needsRepaint: Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        return opacity.isAnimating(now: now) || (opacity.sample(now: now) > 0 &&
            ((!paused && (configuration?.playbackRate ?? 0) > 0) || placement?.isMoving(now: now) == true))
    }

    /// Updates only cached placement/clock state. Asset generations and GPU
    /// resources remain unchanged for GPS, heading, clip and rate updates.
    func update(latitude: Double, longitude: Double, headingDegrees: Double,
                clipIndex: Int?, playbackRate: Double?, opacity newOpacity: Double?,
                opacityTransitionMilliseconds: Int?, skinColor: SIMD4<Float>? = nil,
                eyeColor: SIMD4<Float>? = nil) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let asset, let current = configuration else { return "MODEL_NOT_ATTACHED" }
        let clip = clipIndex ?? current.clipIndex
        guard asset.clips.indices.contains(clip) else { return "INVALID_ARGUMENTS" }
        let now = CACurrentMediaTime()
        let wasHidden = opacity.sample(now: now) == 0 && !opacity.isAnimating(now: now)
        advanceClock(now: now)
        if clip != current.clipIndex { clock.reset() }
        configuration = MoveyRiggedConfiguration(latitude: latitude, longitude: longitude,
            altitudeMeters: current.altitudeMeters, heightMeters: current.heightMeters, headingDegrees: headingDegrees,
            clipIndex: clip, playbackRate: playbackRate ?? current.playbackRate,
            opacity: newOpacity ?? current.opacity,
            skinColor: skinColor ?? current.skinColor, eyeColor: eyeColor ?? current.eyeColor)
        // Establish the same clock boundary for a new rate without a time jump.
        advanceClock(now: now)
        let next = MoveyRiggedPlacement(latitude: latitude, longitude: longitude, headingDegrees: headingDegrees)
        if wasHidden {
            var snapped = MoveyRiggedPlacementTween(next, now: now)
            snapped.setSuspended(!foreground, now: now)
            placement = snapped
        } else {
            placement?.retarget(next, now: now)
        }
        if let newOpacity {
            opacity.retarget(newOpacity, duration: Double(opacityTransitionMilliseconds ?? 0) / 1000, now: now)
        }
        return nil
    }

    /// Caller holds lock, so a clock edge always uses one immutable clip/rate.
    private func advanceClock(now: Double) {
        guard let asset, let configuration else { return }
        clock.tick(now: now, rate: configuration.playbackRate,
                   duration: asset.clips[configuration.clipIndex].duration, playing: !paused)
    }

    func recordError(_ code: String) {
        lock.lock(); lastErrorCode = code; lock.unlock()
    }

    func diagnostics() -> Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return Diagnostics(ready: ready, renderedFrames: renderedFrames, poseRevision: poseRevision,
                           animationTimeSeconds: clock.time, vertexCount: asset?.vertices.count ?? 0,
                           jointCount: asset?.joints.count ?? 0, clipCount: asset?.clips.count ?? 0,
                           clipIndex: configuration?.clipIndex ?? 0, opacity: opacity.sample(now: CACurrentMediaTime()),
                           targetOpacity: opacity.target, isOpacityAnimating: opacity.isAnimating(now: CACurrentMediaTime()),
                           lastErrorCode: lastErrorCode)
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
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            descriptor.depthAttachmentPixelFormat = depth
            if depth == .depth32Float_stencil8 { descriptor.stencilAttachmentPixelFormat = depth }
            let newPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .lessEqual
            guard let newDepthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor) else { recordError("METAL_DEPTH_STATE_UNAVAILABLE"); return }
            depthDescriptor.isDepthWriteEnabled = false
            guard let newTransparentDepthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor) else { recordError("METAL_DEPTH_STATE_UNAVAILABLE"); return }
            device = metalDevice
            pipeline = newPipeline
            depthState = newDepthState
            transparentDepthState = newTransparentDepthState
        } catch { recordError("METAL_PIPELINE_UNAVAILABLE") }
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let device, let pipeline, let depthState else { return }
        lock.lock()
        guard let asset, let configuration, lastErrorCode == nil else { lock.unlock(); return }
        let snapshotGeneration = generation
        let now = CACurrentMediaTime()
        advanceClock(now: now)
        let time = clock.time
        let snapshotOpacity = opacity.sample(now: now)
        let position = placement?.sample(now: now) ?? .init(latitude: configuration.latitude, longitude: configuration.longitude,
                                                          headingDegrees: configuration.headingDegrees)
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
            var uploadedTextures: [(MTLTexture, MTLSamplerState)] = []
            for image in asset.textures {
                guard let texture = makeTexture(image, device: device, commandBuffer: mtlCommandBuffer) else {
                    recordError("METAL_TEXTURE_UNAVAILABLE"); return
                }
                uploadedTextures.append(texture)
            }
            guard let white = makeTexture(nil, device: device, commandBuffer: mtlCommandBuffer),
                  let black = makeTexture(nil, fallback: Data([0, 0, 0, 255]), device: device, commandBuffer: mtlCommandBuffer) else {
                recordError("METAL_TEXTURE_UNAVAILABLE"); return
            }
            textures = uploadedTextures
            whiteTexture = white
            blackTexture = black
            vertexBuffer = newVertices
            indexBuffer = newIndices
            uploadedGeneration = snapshotGeneration
            lock.lock()
            if generation == snapshotGeneration { ready = true }
            lock.unlock()
        }
        // A hidden prewarm uploads real GPU resources but never touches depth.
        guard snapshotOpacity > 0 else { return }
        guard let vertices = vertexBuffer, let indices = indexBuffer, let white = whiteTexture, let black = blackTexture,
              let pose = asset.pose(time: time, clipIndex: configuration.clipIndex),
              var matrix = MoveyGeographicMatrix.make(parameters, latitude: position.latitude, longitude: position.longitude,
                                                       altitudeMeters: configuration.altitudeMeters, sizeMeters: configuration.heightMeters,
                                                       headingDegrees: position.headingDegrees, local: asset.normalizedWorldToMap) else {
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
        encoder.setDepthStencilState(snapshotOpacity == 1 ? depthState : transparentDepthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        pose.palette.withUnsafeBufferPointer { values in
            if let base = values.baseAddress { encoder.setVertexBytes(base, length: values.count * MemoryLayout<simd_float4x4>.stride, index: 2) }
        }
        var visibleOpacity = Float(snapshotOpacity)
        encoder.setFragmentBytes(&visibleOpacity, length: MemoryLayout<Float>.stride, index: 1)
        for part in asset.parts {
            let base = part.textureIndex.map { textures[$0] } ?? white
            let mask = part.tintMaskTextureIndex.map { textures[$0] } ?? black
            var color = part.baseColor
            var palette = [configuration.skinColor, configuration.eyeColor, SIMD4<Float>(part.skin ? 1 : 0, Float(part.tintMode.rawValue), 0, 0)]
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            palette.withUnsafeMutableBufferPointer { values in
                if let address = values.baseAddress { encoder.setFragmentBytes(address, length: values.count * MemoryLayout<SIMD4<Float>>.stride, index: 2) }
            }
            encoder.setFragmentTexture(base.0, index: 0)
            encoder.setFragmentTexture(mask.0, index: 1)
            encoder.setFragmentSamplerState(base.1, index: 0)
            encoder.setFragmentSamplerState(mask.1, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: .uint32,
                indexBuffer: indices, indexBufferOffset: part.firstIndex * MemoryLayout<UInt32>.stride)
        }
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
        transparentDepthState = nil
        vertexBuffer = nil
        indexBuffer = nil
        textures.removeAll()
        whiteTexture = nil
        blackTexture = nil
        uploadedGeneration = -1
        lock.lock(); ready = false; clock.suspend(); lock.unlock()
    }

    private func makeTexture(_ image: MoveyRiggedTexture?, fallback: Data = Data([255, 255, 255, 255]), device: MTLDevice,
                             commandBuffer: MTLCommandBuffer) -> (MTLTexture, MTLSamplerState)? {
        let width = image?.width ?? 1, height = image?.height ?? 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                 mipmapped: image?.requiresMipmaps == true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let rgba = image?.rgba ?? fallback
        rgba.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                                              withBytes: base, bytesPerRow: width * 4) }
        }
        if image?.requiresMipmaps == true {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        let sampler = MTLSamplerDescriptor()
        sampler.magFilter = image?.magFilter == 9728 ? .nearest : .linear
        let min = image?.minFilter ?? 9729
        sampler.minFilter = [9728, 9984, 9986].contains(min) ? .nearest : .linear
        sampler.mipFilter = [9984, 9985].contains(min) ? .nearest : ([9986, 9987].contains(min) ? .linear : .notMipmapped)
        func address(_ value: Int?) -> MTLSamplerAddressMode {
            switch value { case 33071: return .clampToEdge; case 33648: return .mirrorRepeat; default: return .repeat }
        }
        sampler.sAddressMode = address(image?.wrapS)
        sampler.tAddressMode = address(image?.wrapT)
        guard let state = device.makeSamplerState(descriptor: sampler) else { return nil }
        return (texture, state)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct SkinVertex { float4 position; uint4 joints; float4 weights; float2 uv; };
    struct SkinOutput { float4 position [[position]]; float2 uv; };
    vertex SkinOutput moveySkinVertex(uint id [[vertex_id]], constant SkinVertex *vertices [[buffer(0)]],
        constant float4x4 &mvp [[buffer(1)]], constant float4x4 *jointWorldInverseBind [[buffer(2)]]) {
        SkinVertex v = vertices[id];
        float4 world = (jointWorldInverseBind[v.joints.x] * v.position) * v.weights.x
                     + (jointWorldInverseBind[v.joints.y] * v.position) * v.weights.y
                     + (jointWorldInverseBind[v.joints.z] * v.position) * v.weights.z
                     + (jointWorldInverseBind[v.joints.w] * v.position) * v.weights.w;
        SkinOutput output; output.position = mvp * world; output.uv = v.uv; return output;
    }
    float3 srgbToLinear(float3 value) {
        return select(pow((value + 0.055) / 1.055, float3(2.4)), value / 12.92, value <= 0.04045);
    }
    float3 linearToSrgb(float3 value) {
        value = max(value, float3(0.0));
        return select(1.055 * pow(value, float3(1.0 / 2.4)) - 0.055, value * 12.92, value <= 0.0031308);
    }
    float3 customizerHsv(float3 rgb) {
        float maximum = max(rgb.r, max(rgb.g, rgb.b)), minimum = min(rgb.r, min(rgb.g, rgb.b));
        float difference = maximum - minimum;
        if (difference <= 0.0) return float3(0.0, 0.0, maximum);
        float hue;
        if (maximum == rgb.r) hue = (rgb.g - rgb.b) / difference + (rgb.g < rgb.b ? 6.0 : 0.0);
        else if (maximum == rgb.g) hue = (rgb.b - rgb.r) / difference + 2.0;
        else hue = (rgb.r - rgb.g) / difference + 4.0;
        return float3(hue / 6.0, maximum > 0.0 ? difference / maximum : 0.0, maximum);
    }
    float3 customizerRgb(float3 hsv) {
        float3 p = abs(fract(hsv.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
        return hsv.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), hsv.y);
    }
    float customizerLipValue(float3 skin) {
        const float3 reference = float3(0.88792324, 0.38132605, 0.1559265);
        const float3 luminance = float3(0.2126, 0.7152, 0.0722);
        return clamp(sqrt(dot(skin, luminance) / dot(reference, luminance)), 0.2, 1.2);
    }
    float3 customizerColor(float3 base, float3 mask, float3 skin, float3 eye) {
        float3 result = mix(base, base * skin / float3(0.88792324, 0.38132605, 0.1559265), mask.r);
        float3 value = customizerHsv(result), target = customizerHsv(eye);
        const float3 reference = float3(0.03481012658227848, 0.8777777777777778, 0.18);
        value.x = fract(value.x + target.x - reference.x);
        value.y = clamp(value.y * target.y / reference.y, 0.0, 1.0);
        value.z *= clamp(target.z / reference.z, 0.25, 1.4);
        result = mix(result, customizerRgb(value), mask.g);
        return max(result * (1.0 + mask.b * (customizerLipValue(skin) - 1.0)), float3(0.0));
    }
    fragment float4 moveySkinFragment(SkinOutput input [[stage_in]], constant float4 &baseColor [[buffer(0)]],
        constant float &opacity [[buffer(1)]], constant float4 *palette [[buffer(2)]],
        texture2d<float> baseTexture [[texture(0)]], texture2d<float> maskTexture [[texture(1)]],
        sampler baseSampler [[sampler(0)]], sampler maskSampler [[sampler(1)]]) {
        float3 linearBase = srgbToLinear(baseTexture.sample(baseSampler, input.uv).rgb) * baseColor.rgb;
        float3 mask = maskTexture.sample(maskSampler, input.uv).rgb;
        float mode = palette[2].y;
        float3 color;
        if (mode > 2.5) color = linearBase * customizerLipValue(palette[0].rgb);
        else if (mode > 1.5) color = linearBase * palette[0].rgb / float3(0.88792324, 0.38132605, 0.1559265);
        else if (mode > 0.5) color = customizerColor(linearBase, mask, palette[0].rgb, palette[1].rgb);
        else {
            if (palette[2].x > 0.5) mask = float3(1.0, 0.0, 0.0);
            float3 tint = float3(1.0 - mask.r - mask.g) + mask.r * palette[0].rgb + mask.g * palette[1].rgb;
            color = linearBase * tint;
        }
        return float4(linearToSrgb(color), opacity);
    }
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
