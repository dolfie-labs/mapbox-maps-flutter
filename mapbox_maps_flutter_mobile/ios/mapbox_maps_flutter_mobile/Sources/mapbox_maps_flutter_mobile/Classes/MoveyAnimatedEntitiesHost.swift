import CoreFoundation
import Flutter
import Foundation
import Metal
@_spi(Experimental) import MapboxMaps
import QuartzCore
import simd
import UIKit

/// One map-scoped P0 native probe, with additive cube and bounded GLB commands.
final class MoveyAnimatedEntitiesHost: NSObject {
    private static let protocolVersion = 1
    private static let layerId = "movey-animated-entities-p0-cube-v1"
    private static let mercatorLatitudeLimit = 85.05112878
    private weak var mapView: MapView?
    private let channel: FlutterMethodChannel
    private let renderer = MoveyCubeRenderer()
    private let riggedRenderer = MoveyRiggedModelRenderer()
    private let decodeQueue = DispatchQueue(label: "dev.movey.mapbox.glb-decode", qos: .userInitiated)
    private var loadGeneration = 0
    private var cancellation: MoveyGLBCancellation?
    private var pendingResult: FlutterResult?
    private var requestedModel = false
    private var activeRigged = false
    private var modelPlaybackRate = 0.0
    private var modelLoadError: String?
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
        channel = FlutterMethodChannel(name: "dev.movey.mapbox.animated_entities.v1.\(channelSuffix)", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(FlutterError(code: "MAP_DISPOSED", message: "The map has been disposed.", details: nil)); return }
            self.handle(call, result: result)
        }
        styleSubscription = mapView.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            self?.ownsLayer = false
            self?.restoreLayer()
        }
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.foreground = false; self?.syncRepaint() })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.foreground = true; self?.syncRepaint() })
    }

    deinit { dispose() }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        cancelLoad(code: "MAP_DISPOSED")
        attached = false
        requestedModel = false
        renderer.detach()
        riggedRenderer.detach()
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
        guard !disposed, mapView != nil else { result(error("MAP_DISPOSED", "The map has been disposed.")); return }
        guard let arguments = call.arguments as? [String: Any] else { result(error("INVALID_ARGUMENTS", "A command argument map is required.")); return }
        guard let version = number(arguments, "protocolVersion"), version == Double(Self.protocolVersion) else {
            result(error("PROTOCOL_VERSION_UNSUPPORTED", "protocolVersion must be 1.")); return
        }
        switch call.method {
        case "attachCube":
            guard let latitude = number(arguments, "latitude"), abs(latitude) <= Self.mercatorLatitudeLimit,
                  let longitude = number(arguments, "longitude"), abs(longitude) <= 180,
                  let altitude = number(arguments, "altitudeMeters"), let size = number(arguments, "sizeMeters"), size > 0,
                  let heading = number(arguments, "headingDegrees"), let rotation = number(arguments, "rotationDegreesPerSecond"),
                  let paused = boolean(arguments, "paused") else {
                result(error("INVALID_ARGUMENTS", "A cube requires finite Mercator coordinates, a positive size and a paused flag.")); return
            }
            cancelLoad(code: "LOAD_SUPERSEDED")
            let needsReplacement = activeRigged || renderer.diagnostics().lastErrorCode != nil
            if needsReplacement, let failure = removeLayer() { result(failure); return }
            riggedRenderer.detach()
            activeRigged = false
            requestedModel = false
            modelLoadError = nil
            renderer.configure(MoveyCubeConfiguration(latitude: latitude, longitude: longitude, altitudeMeters: altitude,
                                                      sizeMeters: size, headingDegrees: heading, rotationDegreesPerSecond: rotation))
            attached = true
            requestedPaused = paused
            rotationDegreesPerSecond = rotation
            if let failure = installLayerIfReady() { result(failure); return }
            syncRepaint()
            result(nil)
        case "attachRiggedModel":
            attachRiggedModel(arguments, result: result)
        case "updateRiggedModel":
            guard let latitude = number(arguments, "latitude"), abs(latitude) <= Self.mercatorLatitudeLimit,
                  let longitude = number(arguments, "longitude"), abs(longitude) <= 180,
                  let heading = number(arguments, "headingDegrees") else {
                result(error("INVALID_ARGUMENTS", "An update requires finite Mercator coordinates and heading.")); return
            }
            var clipIndex: Int?
            if arguments["clipIndex"] != nil {
                guard let clip = number(arguments, "clipIndex"), clip.rounded(.towardZero) == clip,
                      clip >= 0, clip <= Double(Int32.max) else {
                    result(error("INVALID_ARGUMENTS", "clipIndex must be a nonnegative integer.")); return
                }
                clipIndex = Int(clip)
            }
            var playbackRate: Double?
            if arguments["playbackRate"] != nil {
                guard let rate = number(arguments, "playbackRate"), rate >= 0, rate <= 4 else {
                    result(error("INVALID_ARGUMENTS", "playbackRate must be in [0, 4].")); return
                }
                playbackRate = rate
            }
            var opacity: Double?
            if arguments["opacity"] != nil {
                guard let value = number(arguments, "opacity"), value >= 0, value <= 1 else {
                    result(error("INVALID_ARGUMENTS", "opacity must be in [0, 1].")); return
                }
                opacity = value
            }
            var opacityTransitionMilliseconds: Int?
            if arguments["opacityTransitionMilliseconds"] != nil {
                guard opacity != nil, let duration = number(arguments, "opacityTransitionMilliseconds"),
                      duration.rounded(.towardZero) == duration, duration >= 0, duration <= 1000 else {
                    result(error("INVALID_ARGUMENTS", "An opacity transition requires opacity and an integer duration in [0, 1000].")); return
                }
                opacityTransitionMilliseconds = Int(duration)
            }
            var skinColor: SIMD4<Float>?
            var eyeColor: SIMD4<Float>?
            if arguments["skinColor"] != nil || arguments["skinColorLinear"] != nil {
                guard let color = paletteColor(arguments, "skinColor", fallback: MoveyCharacterPalette.defaultSkin) else {
                    result(error("INVALID_ARGUMENTS", "skinColor must use #RRGGBB or skinColorLinear must contain three components in [0.001, 1].")); return
                }
                skinColor = color
            }
            if arguments["eyeColor"] != nil || arguments["eyeColorLinear"] != nil {
                guard let color = paletteColor(arguments, "eyeColor", fallback: MoveyCharacterPalette.defaultEye) else {
                    result(error("INVALID_ARGUMENTS", "eyeColor must use #RRGGBB or eyeColorLinear must contain three components in [0.001, 1].")); return
                }
                eyeColor = color
            }
            guard attached, activeRigged else {
                result(error("MODEL_NOT_ATTACHED", "A CPU-accepted rigged model is required before an update.")); return
            }
            if let code = riggedRenderer.update(latitude: latitude, longitude: longitude, headingDegrees: heading,
                                                 clipIndex: clipIndex, playbackRate: playbackRate, opacity: opacity,
                                                 opacityTransitionMilliseconds: opacityTransitionMilliseconds,
                                                 skinColor: skinColor, eyeColor: eyeColor) {
                result(error(code, "The model update could not be accepted.")); return
            }
            if let playbackRate { modelPlaybackRate = playbackRate }
            syncRepaint()
            result(nil)
        case "setPaused":
            guard let paused = boolean(arguments, "paused") else { result(error("INVALID_ARGUMENTS", "paused must be a boolean.")); return }
            requestedPaused = paused
            syncRepaint()
            result(nil)
        case "detach":
            cancelLoad(code: "LOAD_SUPERSEDED")
            attached = false
            requestedModel = false
            modelLoadError = nil
            renderer.detach()
            riggedRenderer.detach()
            stopRepaint()
            result(removeLayer())
        case "getDiagnostics":
            let state = renderer.diagnostics()
            result(["protocolVersion": Self.protocolVersion, "backend": "iosMetal", "attached": attached && !activeRigged,
                    "paused": requestedPaused, "styleLayerPresent": ownsLayer && mapView?.mapboxMap.layerExists(withId: Self.layerId) == true,
                    "initialized": !activeRigged && state.initialized, "repaintEnabled": !activeRigged && displayLink != nil,
                    "renderedFrames": state.renderedFrames, "lastErrorCode": state.lastErrorCode.map { $0 as Any } ?? NSNull(),
                    "supportsSkeletalAnimation": false])
        case "getRiggedModelDiagnostics":
            let state = riggedRenderer.diagnostics()
            let failure = modelLoadError ?? state.lastErrorCode
            result(["protocolVersion": Self.protocolVersion, "backend": "iosMetal", "requested": requestedModel,
                    "ready": attached && activeRigged && state.ready, "paused": requestedPaused,
                    "repaintEnabled": activeRigged && displayLink != nil, "renderedFrames": state.renderedFrames,
                    "poseRevision": state.poseRevision, "animationTimeSeconds": state.animationTimeSeconds,
                    "vertexCount": state.vertexCount, "jointCount": state.jointCount, "clipCount": state.clipCount,
                    "clipIndex": state.clipIndex, "lastErrorCode": failure.map { $0 as Any } ?? NSNull(),
                    "opacity": state.opacity, "targetOpacity": state.targetOpacity, "isOpacityAnimating": state.isOpacityAnimating,
                    "incomingGlErrorCode": NSNull()])
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func attachRiggedModel(_ arguments: [String: Any], result: @escaping FlutterResult) {
        guard let bytes = arguments["glbBytes"] as? FlutterStandardTypedData,
              let latitude = number(arguments, "latitude"), abs(latitude) <= Self.mercatorLatitudeLimit,
              let longitude = number(arguments, "longitude"), abs(longitude) <= 180,
              let altitude = number(arguments, "altitudeMeters"), let height = number(arguments, "heightMeters"), height > 0,
              let heading = number(arguments, "headingDegrees"), let clip = number(arguments, "clipIndex"),
              clip.rounded(.towardZero) == clip, clip >= 0, clip <= Double(Int32.max),
              let rate = number(arguments, "playbackRate"), rate >= 0, rate <= 4,
              let paused = boolean(arguments, "paused") else {
            result(error("INVALID_ARGUMENTS", "A rigged model requires GLB bytes, finite Mercator placement, a positive height, clip index and playback rate in [0, 4].")); return
        }
        guard bytes.data.count <= MoveyGLBDecoder.maximumBytes else { result(error("GLB_TOO_LARGE", "A character GLB must be at most 8 MiB.")); return }
        var opacity = 1.0
        if arguments["opacity"] != nil {
            guard let value = number(arguments, "opacity"), value >= 0, value <= 1 else {
                result(error("INVALID_ARGUMENTS", "opacity must be in [0, 1].")); return
            }
            opacity = value
        }
        guard let skinColor = paletteColor(arguments, "skinColor", fallback: MoveyCharacterPalette.defaultSkin),
              let eyeColor = paletteColor(arguments, "eyeColor", fallback: MoveyCharacterPalette.defaultEye) else {
            result(error("INVALID_ARGUMENTS", "skinColor and eyeColor must use #RRGGBB or eyeColorLinear must contain three components in [0.001, 1].")); return
        }
        cancelLoad(code: "LOAD_SUPERSEDED")
        let generation = loadGeneration
        let token = MoveyGLBCancellation()
        cancellation = token
        pendingResult = result
        requestedModel = true
        modelLoadError = nil
        let data = bytes.data
        let hasSkinOverride = arguments["skinColor"] != nil || arguments["skinColorLinear"] != nil
        let hasEyeOverride = arguments["eyeColor"] != nil || arguments["eyeColorLinear"] != nil
        decodeQueue.async { [weak self] in
            let decoded: Result<MoveyRiggedAsset, Error> = Result {
                let asset = try MoveyGLBDecoder.decode(data, cancellation: token)
                guard asset.clips.indices.contains(Int(clip)) else { throw MoveyGLBFailure.invalid("clipIndex is outside the GLB clips.") }
                return asset
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.disposed, self.loadGeneration == generation else { return }
                self.cancellation = nil
                guard let completion = self.pendingResult else { return }
                self.pendingResult = nil
                switch decoded {
                case .failure(let failure):
                    let typed = failure as? MoveyGLBFailure ?? .invalid("The GLB JSON or binary content is invalid.")
                    self.modelLoadError = typed.code
                    completion(self.error(typed.code, typed.message))
                case .success(let asset):
                    let configuration = MoveyRiggedConfiguration(latitude: latitude, longitude: longitude, altitudeMeters: altitude,
                        heightMeters: height, headingDegrees: heading, clipIndex: Int(clip), playbackRate: rate, opacity: opacity,
                        skinColor: asset.usesCustomizer && !hasSkinOverride ? MoveyCharacterPalette.customizerSkin : skinColor,
                        eyeColor: asset.usesCustomizer && !hasEyeOverride ? MoveyCharacterPalette.customizerEye : eyeColor)
                    // CPU acceptance is transactional: failed decoding never removes the old probe.
                    if self.attached, !self.activeRigged, let failure = self.removeLayer() {
                        self.modelLoadError = failure.code
                        completion(failure)
                        return
                    }
                    // Existing model layer can reuse its render context; GPU buffers are
                    // replaced on the next native render callback, never on this queue.
                    self.renderer.detach()
                    self.riggedRenderer.configure(asset: asset, configuration: configuration)
                    self.activeRigged = true
                    self.attached = true
                    self.requestedPaused = paused
                    self.modelPlaybackRate = rate
                    self.modelLoadError = nil
                    if let failure = self.installLayerIfReady() { completion(failure); return }
                    self.syncRepaint()
                    // A successful command means CPU accepted. Diagnostics.ready is only
                    // set by the render callback after real Metal buffers are allocated.
                    completion(nil)
                }
            }
        }
    }

    private func cancelLoad(code: String) {
        loadGeneration += 1
        cancellation?.cancel()
        cancellation = nil
        let completion = pendingResult
        pendingResult = nil
        completion?(error(code, code == "MAP_DISPOSED" ? "The map has been disposed." : "The model load was superseded."))
    }

    private func error(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
    private func number(_ arguments: [String: Any], _ key: String) -> Double? {
        guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private func paletteColor(_ arguments: [String: Any], _ key: String, fallback: String) -> SIMD4<Float>? {
        if let linear = arguments[key + "Linear"] { return MoveyCharacterPalette.linearComponents(linear) }
        guard let value = (arguments[key] ?? fallback) as? String else { return nil }
        return MoveyCharacterPalette.linear(value)
    }
    private func boolean(_ arguments: [String: Any], _ key: String) -> Bool? {
        guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private var activeError: String? { activeRigged ? riggedRenderer.diagnostics().lastErrorCode : renderer.diagnostics().lastErrorCode }
    private func recordActiveError(_ code: String) {
        if activeRigged { riggedRenderer.recordError(code) } else { renderer.recordError(code) }
    }

    private func restoreLayer() {
        guard !disposed, attached else { return }
        if let failure = installLayerIfReady() { recordActiveError(failure.code); stopRepaint(); return }
        syncRepaint()
    }
    private func installLayerIfReady() -> FlutterError? {
        guard attached, let map = mapView?.mapboxMap, map.isStyleLoaded else { return nil }
        if map.layerExists(withId: Self.layerId) {
            guard ownsLayer else {
                recordActiveError("STYLE_LAYER_ID_CONFLICT")
                stopRepaint()
                return error("STYLE_LAYER_ID_CONFLICT", "The probe layer ID belongs to the caller's style.")
            }
            return nil
        }
        ownsLayer = false
        do {
            let layerRenderer: CustomLayerHost = activeRigged ? riggedRenderer : renderer
            try map.addLayer(CustomLayer(id: Self.layerId, renderer: layerRenderer))
            ownsLayer = true
            return nil
        } catch {
            recordActiveError("STYLE_LAYER_ADD_FAILED")
            stopRepaint()
            return self.error("STYLE_LAYER_ADD_FAILED", "The native custom layer could not be attached.")
        }
    }
    @discardableResult private func removeLayer() -> FlutterError? {
        guard ownsLayer else { return nil }
        guard let map = mapView?.mapboxMap, map.layerExists(withId: Self.layerId) else { ownsLayer = false; return nil }
        do { try map.removeLayer(withId: Self.layerId); ownsLayer = false; return nil }
        catch { recordActiveError("STYLE_LAYER_REMOVE_FAILED"); return self.error("STYLE_LAYER_REMOVE_FAILED", "The native custom layer could not be removed.") }
    }
    private func syncRepaint() {
        renderer.setPaused(requestedPaused || !foreground)
        riggedRenderer.setForeground(foreground)
        riggedRenderer.setPaused(requestedPaused || !foreground)
        guard !disposed, attached, foreground, ownsLayer,
              let map = mapView?.mapboxMap, map.layerExists(withId: Self.layerId), activeError == nil else { stopRepaint(); return }
        map.triggerRepaint()
        let advances = activeRigged ? riggedRenderer.needsRepaint
                                    : (!requestedPaused && rotationDegreesPerSecond != 0)
        guard advances else { stopRepaint(); return }
        guard displayLink == nil else { return }
        let target = MoveyCubeDisplayLinkTarget(host: self)
        let link = CADisplayLink(target: target, selector: #selector(MoveyCubeDisplayLinkTarget.tick))
        link.preferredFramesPerSecond = 30
        displayLinkTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }
    fileprivate func repaint() {
        guard !disposed, attached, foreground, ownsLayer,
              let map = mapView?.mapboxMap, map.layerExists(withId: Self.layerId), activeError == nil else { stopRepaint(); return }
        // Trigger the endpoint frame before stopping a paused placement tween.
        map.triggerRepaint()
        let advances = activeRigged ? riggedRenderer.needsRepaint
                                    : (!requestedPaused && rotationDegreesPerSecond != 0)
        if !advances { stopRepaint() }
    }
    private func stopRepaint() { displayLink?.invalidate(); displayLink = nil; displayLinkTarget = nil }
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
        MoveyGeographicMatrix.make(parameters, latitude: configuration.latitude, longitude: configuration.longitude,
                                  altitudeMeters: configuration.altitudeMeters, sizeMeters: configuration.sizeMeters,
                                  headingDegrees: headingDegrees)
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
