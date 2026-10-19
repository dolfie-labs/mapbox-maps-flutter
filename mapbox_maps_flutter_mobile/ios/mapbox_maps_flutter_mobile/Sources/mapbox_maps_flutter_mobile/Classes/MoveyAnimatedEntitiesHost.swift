import CoreFoundation
import Flutter
import Foundation
import Metal
@_spi(Experimental) import MapboxMaps
import QuartzCore
import simd
import UIKit

/// P0 cube experiment, scoped to one existing MapView. This is not a GLB scene.
final class MoveyAnimatedEntitiesHost: NSObject {
    private static let protocolVersion = 1
    private static let layerId = "movey-animated-entities-p0-cube-v1"
    private static let mercatorLatitudeLimit = 85.05112878

    private weak var mapView: MapView?
    private let channel: FlutterMethodChannel
    private let renderer = MoveyCubeRenderer()
    private var styleSubscription: AnyCancelable?
    private var notificationTokens: [NSObjectProtocol] = []
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: MoveyCubeDisplayLinkTarget?
    private var attached = false
    private var ownsLayer = false
    private var requestedPaused = false
    private var foreground = UIApplication.shared.applicationState == .active
    private var disposed = false
    private var rotationDegreesPerSecond = 0.0

    init(mapView: MapView, messenger: FlutterBinaryMessenger, channelSuffix: String) {
        self.mapView = mapView
        channel = FlutterMethodChannel(
            name: "dev.movey.mapbox.animated_entities.v1.\(channelSuffix)",
            binaryMessenger: messenger
        )
        super.init()

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "MAP_DISPOSED", message: "The map has been disposed.", details: nil))
                return
            }
            self.handle(call, result: result)
        }
        styleSubscription = mapView.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            // Our non-persistent layer belonged to the previous style. A layer
            // with this ID in the newly loaded style does not belong to us.
            self?.ownsLayer = false
            self?.restoreLayer()
        }
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.foreground = false
            self?.syncRepaint()
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.foreground = true
            self?.syncRepaint()
        })
    }

    deinit {
        dispose()
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        attached = false
        renderer.detach()
        stopRepaint()
        styleSubscription?.cancel()
        styleSubscription = nil
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        channel.setMethodCallHandler(nil)
        removeLayer()
        mapView = nil
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard !disposed, mapView != nil else {
            result(FlutterError(code: "MAP_DISPOSED", message: "The map has been disposed.", details: nil))
            return
        }
        guard let arguments = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "A command argument map is required.", details: nil))
            return
        }
        guard let version = number(arguments, "protocolVersion"),
              version == Double(Self.protocolVersion) else {
            result(FlutterError(code: "PROTOCOL_VERSION_UNSUPPORTED", message: "protocolVersion must be 1.", details: nil))
            return
        }
        switch call.method {
        case "attachCube":
            guard let latitude = number(arguments, "latitude"),
                  abs(latitude) <= Self.mercatorLatitudeLimit,
                  let longitude = number(arguments, "longitude"), abs(longitude) <= 180,
                  let altitude = number(arguments, "altitudeMeters"),
                  let size = number(arguments, "sizeMeters"), size > 0,
                  let heading = number(arguments, "headingDegrees"),
                  let rotation = number(arguments, "rotationDegreesPerSecond"),
                  let paused = boolean(arguments, "paused") else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "A cube requires finite Mercator coordinates, a positive size and a paused flag.", details: nil))
                return
            }
            let retryResources = renderer.diagnostics().lastErrorCode != nil
            renderer.configure(MoveyCubeConfiguration(
                latitude: latitude, longitude: longitude, altitudeMeters: altitude,
                sizeMeters: size, headingDegrees: heading,
                rotationDegreesPerSecond: rotation
            ))
            attached = true
            requestedPaused = paused
            rotationDegreesPerSecond = rotation
            if retryResources, let error = removeLayer() {
                result(error)
                return
            }
            if let error = installLayerIfReady() {
                result(error)
                return
            }
            syncRepaint()
            result(nil)
        case "setPaused":
            guard let paused = boolean(arguments, "paused") else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "paused must be a boolean.", details: nil))
                return
            }
            requestedPaused = paused
            syncRepaint()
            result(nil)
        case "detach":
            attached = false
            renderer.detach()
            stopRepaint()
            if let error = removeLayer() {
                result(error)
            } else {
                result(nil)
            }
        case "getDiagnostics":
            let state = renderer.diagnostics()
            result([
                "protocolVersion": Self.protocolVersion,
                "backend": "iosMetal",
                "attached": attached,
                "paused": requestedPaused,
                "styleLayerPresent": ownsLayer && mapView?.mapboxMap.layerExists(withId: Self.layerId) == true,
                "initialized": state.initialized,
                "repaintEnabled": displayLink != nil,
                "renderedFrames": state.renderedFrames,
                "lastErrorCode": state.lastErrorCode.map { $0 as Any } ?? NSNull(),
                "supportsSkeletalAnimation": false
            ])
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func number(_ arguments: [String: Any], _ key: String) -> Double? {
        guard let value = arguments[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private func boolean(_ arguments: [String: Any], _ key: String) -> Bool? {
        guard let value = arguments[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private func restoreLayer() {
        guard !disposed, attached else { return }
        if let error = installLayerIfReady() {
            // No pending Flutter command exists during a style callback; retain
            // the typed error in diagnostics and stop the native repaint loop.
            renderer.recordError(error.code)
            stopRepaint()
            return
        }
        syncRepaint()
    }

    private func installLayerIfReady() -> FlutterError? {
        guard attached, let map = mapView?.mapboxMap, map.isStyleLoaded else { return nil }
        if map.layerExists(withId: Self.layerId) {
            guard ownsLayer else {
                renderer.recordError("STYLE_LAYER_ID_CONFLICT")
                stopRepaint()
                return FlutterError(code: "STYLE_LAYER_ID_CONFLICT", message: "The cube layer ID belongs to the caller's style.", details: nil)
            }
            return nil
        }
        ownsLayer = false
        do {
            // Add one layer without replacing the caller's MapStyleContent.
            try map.addLayer(CustomLayer(id: Self.layerId, renderer: renderer))
            ownsLayer = true
            return nil
        } catch {
            renderer.recordError("STYLE_LAYER_ADD_FAILED")
            stopRepaint()
            return FlutterError(code: "STYLE_LAYER_ADD_FAILED", message: "The native custom layer could not be attached.", details: nil)
        }
    }

    @discardableResult
    private func removeLayer() -> FlutterError? {
        guard ownsLayer else { return nil }
        guard let map = mapView?.mapboxMap, map.layerExists(withId: Self.layerId) else {
            ownsLayer = false
            return nil
        }
        do {
            try map.removeLayer(withId: Self.layerId)
            ownsLayer = false
            return nil
        } catch {
            renderer.recordError("STYLE_LAYER_REMOVE_FAILED")
            return FlutterError(code: "STYLE_LAYER_REMOVE_FAILED", message: "The native custom layer could not be removed.", details: nil)
        }
    }

    private func syncRepaint() {
        renderer.setPaused(requestedPaused || !foreground)
        guard !disposed, attached, foreground, ownsLayer,
              let map = mapView?.mapboxMap, map.layerExists(withId: Self.layerId),
              renderer.diagnostics().lastErrorCode == nil else {
            stopRepaint()
            return
        }
        map.triggerRepaint()
        guard !requestedPaused, rotationDegreesPerSecond != 0 else {
            stopRepaint()
            return
        }
        guard displayLink == nil else { return }
        let target = MoveyCubeDisplayLinkTarget(host: self)
        let link = CADisplayLink(target: target, selector: #selector(MoveyCubeDisplayLinkTarget.tick))
        link.preferredFramesPerSecond = 30
        displayLinkTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    fileprivate func repaint() {
        guard !disposed, attached, foreground, ownsLayer, !requestedPaused,
              let map = mapView?.mapboxMap, map.layerExists(withId: Self.layerId),
              renderer.diagnostics().lastErrorCode == nil else {
            stopRepaint()
            return
        }
        map.triggerRepaint()
    }

    private func stopRepaint() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }
}

/// CADisplayLink retains its target, so this proxy must only weakly own the host.
private final class MoveyCubeDisplayLinkTarget: NSObject {
    private weak var host: MoveyAnimatedEntitiesHost?
    init(host: MoveyAnimatedEntitiesHost) { self.host = host }
    @objc func tick() { host?.repaint() }
}

private struct MoveyCubeConfiguration {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double
    let sizeMeters: Double
    let headingDegrees: Double
    let rotationDegreesPerSecond: Double
}

/// GPU resources only live on Mapbox's rendering callbacks; configuration and
/// diagnostics cross the main/render boundary through immutable lock snapshots.
private final class MoveyCubeRenderer: NSObject, CustomLayerHost {
    private struct Vertex {
        let position: SIMD4<Float>
        let color: SIMD4<Float>
    }
    private let lock = NSLock()
    private var configuration: MoveyCubeConfiguration?
    private var paused = true
    private var rotationDegrees = 0.0
    private var lastFrameTime: CFTimeInterval?
    private var initialized = false
    private var renderedFrames = 0
    private var lastErrorCode: String?
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var vertices: MTLBuffer?

    func configure(_ configuration: MoveyCubeConfiguration) {
        lock.lock()
        self.configuration = configuration
        lastFrameTime = nil
        lastErrorCode = nil
        lock.unlock()
    }

    func detach() {
        lock.lock()
        configuration = nil
        paused = true
        lastFrameTime = nil
        lock.unlock()
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        if self.paused != paused { lastFrameTime = nil }
        self.paused = paused
        lock.unlock()
    }

    func recordError(_ code: String) {
        lock.lock()
        lastErrorCode = code
        lock.unlock()
    }

    func diagnostics() -> (initialized: Bool, renderedFrames: Int, lastErrorCode: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (initialized, renderedFrames, lastErrorCode)
    }

    func renderingWillStart(_ metalDevice: MTLDevice, colorPixelFormat: UInt, depthStencilPixelFormat: UInt) {
        releaseGPUResources()
        guard let colorFormat = MTLPixelFormat(rawValue: colorPixelFormat), colorFormat != .invalid,
              let depthFormat = MTLPixelFormat(rawValue: depthStencilPixelFormat) else {
            recordError("METAL_PIXEL_FORMAT_UNSUPPORTED")
            return
        }
        do {
            // Compile once for each Mapbox render-context lifetime, never in render().
            let library = try metalDevice.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertexFunction = library.makeFunction(name: "moveyCubeVertex"),
                  let fragmentFunction = library.makeFunction(name: "moveyCubeFragment") else {
                recordError("METAL_SHADER_UNAVAILABLE")
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Movey P0 geographic cube"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depthFormat
            if depthFormat == .depth32Float_stencil8 {
                descriptor.stencilAttachmentPixelFormat = depthFormat
            }
            let newPipeline = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .lessEqual
            guard let newDepthState = metalDevice.makeDepthStencilState(descriptor: depthDescriptor) else {
                recordError("METAL_DEPTH_STATE_UNAVAILABLE")
                return
            }
            let data = Self.cubeVertices()
            let newVertices = data.withUnsafeBufferPointer { buffer -> MTLBuffer? in
                guard let address = buffer.baseAddress else { return nil }
                return metalDevice.makeBuffer(bytes: address, length: MemoryLayout<Vertex>.stride * buffer.count, options: [])
            }
            guard let newVertices else {
                recordError("METAL_BUFFER_UNAVAILABLE")
                return
            }
            pipeline = newPipeline
            depthState = newDepthState
            vertices = newVertices
            lock.lock()
            initialized = true
            lock.unlock()
        } catch {
            recordError("METAL_PIPELINE_UNAVAILABLE")
        }
    }

    func render(_ parameters: CustomLayerRenderParameters, mtlCommandBuffer: MTLCommandBuffer, mtlRenderPassDescriptor: MTLRenderPassDescriptor) {
        guard let pipeline, let depthState, let vertices else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        guard let configuration, lastErrorCode == nil else {
            lock.unlock()
            return
        }
        if !paused {
            if let previous = lastFrameTime {
                rotationDegrees = (rotationDegrees + (now - previous) * configuration.rotationDegreesPerSecond)
                    .truncatingRemainder(dividingBy: 360)
            }
            lastFrameTime = now
        } else {
            lastFrameTime = nil
        }
        let heading = configuration.headingDegrees + rotationDegrees
        lock.unlock()

        guard var matrix = modelViewProjection(parameters, configuration: configuration, headingDegrees: heading) else {
            recordError("INVALID_TRANSFORM")
            return
        }
        guard let texture = mtlRenderPassDescriptor.colorAttachments[0].texture,
              let encoder = mtlCommandBuffer.makeRenderCommandEncoder(descriptor: mtlRenderPassDescriptor) else {
            recordError("METAL_ENCODER_UNAVAILABLE")
            return
        }
        encoder.label = "Movey P0 cube in Mapbox pass"
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
        encoder.endEncoding()
        // The command buffer belongs to Mapbox: never commit or present it here.
        lock.lock()
        renderedFrames += 1
        lock.unlock()
    }

    func renderingWillEnd() { releaseGPUResources() }

    private func releaseGPUResources() {
        pipeline = nil
        depthState = nil
        vertices = nil
        lock.lock()
        initialized = false
        lastFrameTime = nil
        lock.unlock()
    }

    private func modelViewProjection(_ parameters: CustomLayerRenderParameters, configuration: MoveyCubeConfiguration, headingDegrees: Double) -> simd_float4x4? {
        let location = CLLocationCoordinate2D(latitude: configuration.latitude, longitude: configuration.longitude)
        let mercator = MapboxMaps.Projection.latLngToMercatorXY(coordinate: location)
        let worldSize = MapboxMaps.Projection.worldSize(scale: pow(2, parameters.zoom))
        let pixelsPerMeter = 1 / MapboxMaps.Projection.metersPerPoint(for: configuration.latitude, zoom: parameters.zoom)
        let heightScale = MapboxMaps.Projection.getLatitudeScale(parameters.latitude) / MapboxMaps.Projection.getLatitudeScale(configuration.latitude)
        var translation = matrix_identity_double4x4
        translation.columns.3 = SIMD4(mercator.x * worldSize, mercator.y * worldSize, configuration.altitudeMeters * heightScale, 1)
        var scale = matrix_identity_double4x4
        scale.columns.0.x = configuration.sizeMeters * pixelsPerMeter
        scale.columns.1.y = configuration.sizeMeters * pixelsPerMeter
        scale.columns.2.z = configuration.sizeMeters * heightScale
        let angle = headingDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        let rotation = simd_double4x4(columns: (
            SIMD4(cos(angle), sin(angle), 0, 0),
            SIMD4(-sin(angle), cos(angle), 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)
        ))
        let model = translation * scale * rotation
        let numbers = (0..<4).flatMap { column in (0..<4).map { row in NSNumber(value: model[column][row]) } }
        guard numbers.allSatisfy({ $0.doubleValue.isFinite }),
              let converted = parameters.projection.convertMercatorModelMatrix(forMatrix: numbers, ignoreDistortion: false),
              let world = doubleMatrix(converted), let projection = doubleMatrix(parameters.projectionMatrix) else { return nil }
        // Keep geographic translations in Double until MVP multiplication avoids
        // subtracting large world coordinates in a Float vertex shader.
        let result = projection * world
        let columns = (0..<4).map { column in SIMD4<Float>(
            Float(result[column][0]), Float(result[column][1]), Float(result[column][2]), Float(result[column][3])
        ) }
        guard columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }) else { return nil }
        return simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
    }

    private func doubleMatrix(_ numbers: [NSNumber]) -> simd_double4x4? {
        guard numbers.count == 16, numbers.allSatisfy({ $0.doubleValue.isFinite }) else { return nil }
        let columns = (0..<4).map { column in SIMD4<Double>(
            numbers[column * 4].doubleValue, numbers[column * 4 + 1].doubleValue,
            numbers[column * 4 + 2].doubleValue, numbers[column * 4 + 3].doubleValue
        ) }
        return simd_double4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
    }

    private static func cubeVertices() -> [Vertex] {
        // One local unit cube, foot at z=0. Geographic size is applied once.
        let points: [SIMD4<Float>] = [
            SIMD4(-0.5, -0.5, 0, 1), SIMD4(0.5, -0.5, 0, 1),
            SIMD4(0.5, 0.5, 0, 1), SIMD4(-0.5, 0.5, 0, 1),
            SIMD4(-0.5, -0.5, 1, 1), SIMD4(0.5, -0.5, 1, 1),
            SIMD4(0.5, 0.5, 1, 1), SIMD4(-0.5, 0.5, 1, 1)
        ]
        let faces = [[0, 1, 5, 0, 5, 4], [2, 3, 7, 2, 7, 6], [3, 0, 4, 3, 4, 7],
                     [1, 2, 6, 1, 6, 5], [4, 5, 6, 4, 6, 7], [3, 2, 1, 3, 1, 0]]
        let colors: [SIMD4<Float>] = [SIMD4(1, 0.2, 0.2, 1), SIMD4(0.2, 1, 0.2, 1),
                                    SIMD4(0.2, 0.4, 1, 1), SIMD4(1, 0.8, 0.1, 1),
                                    SIMD4(0.1, 1, 1, 1), SIMD4(1, 0.2, 1, 1)]
        return faces.enumerated().flatMap { index, face in face.map { Vertex(position: points[$0], color: colors[index]) } }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct MoveyVertex { float4 position; float4 color; };
    struct MoveyVertexOut { float4 position [[position]]; float4 color; };
    vertex MoveyVertexOut moveyCubeVertex(uint id [[vertex_id]],
        constant MoveyVertex *vertices [[buffer(0)]], constant float4x4 &mvp [[buffer(1)]]) {
        MoveyVertexOut output;
        output.position = mvp * vertices[id].position;
        output.color = vertices[id].color;
        return output;
    }
    fragment float4 moveyCubeFragment(MoveyVertexOut input [[stage_in]]) { return input.color; }
    """
}
