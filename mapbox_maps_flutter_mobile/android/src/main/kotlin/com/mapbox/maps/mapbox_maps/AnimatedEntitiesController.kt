package com.mapbox.maps.mapbox_maps

import android.view.Choreographer
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.mapbox.bindgen.Value
import com.mapbox.common.Cancelable
import com.mapbox.maps.MapView
import com.mapbox.maps.MapboxMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Future
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Map-scoped experimental probes. Existing Mapbox channels remain separate. */
internal class AnimatedEntitiesController(
  private val mapView: MapView,
  private val mapboxMap: MapboxMap,
  messenger: BinaryMessenger,
  channelSuffix: String,
) : MethodChannel.MethodCallHandler, DefaultLifecycleObserver {

  private val channel = MethodChannel(
    messenger,
    "dev.movey.mapbox.animated_entities.v1.$channelSuffix",
  )
  private val cube = AtomicReference<AnimatedCubeState?>(null)
  private val rigged = AtomicReference<RiggedModelState?>(null)
  private val renderedFrames = AtomicLong()
  private val choreographer = Choreographer.getInstance()
  // Style events may arrive before their main-thread work runs. Ownership must
  // follow the style generation, rather than the lifetime of a host reference.
  private val styleGeneration = AtomicLong()
  private var host: ProbeGlesHost? = null
  private var ownedHostStyleGeneration = -1L
  private val mainHandler = Handler(Looper.getMainLooper())
  private val loader = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(1))
  private var loadTask: Future<*>? = null
  private var loadResult: MethodChannel.Result? = null
  private var loadGeneration = 0L
  private var modelRequested = false
  private var modelLoadError: String? = null
  private var lifecycle: Lifecycle? = null
  private var viewAttached = false
  private var paused = false
  private var disposed = false
  private var framePosted = false
  private var previousFrameNanos = 0L
  private var lastErrorCode: String? = null
  private val styleSubscription: Cancelable

  private val frameCallback = object : Choreographer.FrameCallback {
    override fun doFrame(frameTimeNanos: Long) {
      framePosted = false
      if (!canRepaint()) {
        previousFrameNanos = 0L
        return
      }
      if (previousFrameNanos != 0L) {
        val model = rigged.get()
        if (model != null) {
          if (!paused) model.advanceAnimation(frameTimeNanos - previousFrameNanos)
        } else {
          cube.get()?.elapsedNanos?.addAndGet(frameTimeNanos - previousFrameNanos)
        }
      }
      previousFrameNanos = frameTimeNanos
      mapboxMap.triggerRepaint()
      updateRepaint()
    }
  }

  init {
    channel.setMethodCallHandler(this)
    styleSubscription = mapboxMap.subscribeStyleLoaded {
      val generation = styleGeneration.incrementAndGet()
      // Map/style work and Flutter channels stay on the Android main thread.
      mapView.post {
        if (disposed || generation != styleGeneration.get()) return@post
        discardStaleHost()
        if (hasActiveProbe()) {
          try {
            installLayerIfNeeded()
            // A static cube still needs a frame after style restoration.
            mapboxMap.triggerRepaint()
          } catch (error: CubeStyleException) {
            lastErrorCode = error.code
          } catch (_: RuntimeException) {
            lastErrorCode = "STYLE_LAYER_ADD_FAILED"
          }
          updateRepaint()
        }
      }
    }
  }

  fun onFlutterViewAttached(parentLifecycle: Lifecycle?) {
    if (disposed) return
    lifecycle?.removeObserver(this)
    lifecycle = parentLifecycle
    viewAttached = true
    parentLifecycle?.addObserver(this)
    updateRepaint()
  }

  fun onFlutterViewDetached() {
    viewAttached = false
    lifecycle?.removeObserver(this)
    lifecycle = null
    updateRepaint()
  }

  override fun onResume(owner: LifecycleOwner) = updateRepaint()

  override fun onPause(owner: LifecycleOwner) {
    // Stop immediately without changing the caller's explicit pause preference.
    stopRepaint()
  }

  override fun onStop(owner: LifecycleOwner) = stopRepaint()

  override fun onDestroy(owner: LifecycleOwner) {
    viewAttached = false
    stopRepaint()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (disposed) {
      result.error("MAP_DISPOSED", "The native map has been disposed.", null)
      return
    }
    val arguments = call.arguments as? Map<*, *>
    if (arguments == null) {
      result.error("INVALID_ARGUMENTS", "A command argument map is required.", null)
      return
    }
    val version = arguments["protocolVersion"]
    if (version != PROTOCOL_VERSION && version != PROTOCOL_VERSION.toLong()) {
      result.error("PROTOCOL_VERSION_UNSUPPORTED", "protocolVersion must be 1.", null)
      return
    }
    try {
      when (call.method) {
        "attachCube" -> {
          val nextCube = readCube(arguments)
          val nextPaused = readPaused(arguments)
          cancelPendingLoad("LOAD_SUPERSEDED")
          lastErrorCode = null
          // A failed GPU initialization is retried only by an explicit attach.
          if (rigged.get() != null || host?.lastErrorCode?.get() != null) removeLayer()
          host?.incomingGlErrorCode?.set(null)
          rigged.set(null)
          modelRequested = false
          modelLoadError = null
          cube.set(nextCube)
          paused = nextPaused
          previousFrameNanos = 0L
          installLayerIfNeeded()
          updateRepaint()
          mapboxMap.triggerRepaint()
          result.success(null)
        }
        "attachRiggedModel" -> attachRiggedModel(arguments, result)
        "updateRiggedModel" -> {
          updateRiggedModel(arguments)
          result.success(null)
        }
        "getRiggedModelDiagnostics" -> result.success(riggedDiagnostics())
        "setPaused" -> {
          paused = readPaused(arguments)
          updateRepaint()
          result.success(null)
        }
        "detach" -> {
          cancelPendingLoad("LOAD_SUPERSEDED")
          cube.set(null)
          rigged.set(null)
          modelRequested = false
          modelLoadError = null
          stopRepaint()
          removeLayer()
          if (lastErrorCode == "STYLE_LAYER_ID_CONFLICT") {
            throw CubeStyleException("STYLE_LAYER_ID_CONFLICT")
          }
          lastErrorCode = null
          result.success(null)
        }
        "getDiagnostics" -> result.success(diagnostics())
        else -> result.notImplemented()
      }
    } catch (error: GlbException) {
      result.error(error.code, "The GLB cannot be used by this native probe.", null)
    } catch (_: IllegalArgumentException) {
      result.error("INVALID_ARGUMENTS", "The cube command has invalid fields.", null)
    } catch (error: CubeStyleException) {
      lastErrorCode = error.code
      stopRepaint()
      result.error(error.code, "The native cube layer could not be updated.", null)
    } catch (_: RuntimeException) {
      lastErrorCode = "STYLE_LAYER_ADD_FAILED"
      stopRepaint()
      result.error("STYLE_LAYER_ADD_FAILED", "The native cube layer could not be added.", null)
    }
  }

  private fun readCube(arguments: Map<*, *>): AnimatedCubeState {
    fun number(key: String): Double {
      val value = arguments[key]
      require(value is Double && value.isFinite())
      return value
    }
    val latitude = number("latitude")
    val longitude = number("longitude")
    val altitude = number("altitudeMeters")
    val size = number("sizeMeters")
    val heading = number("headingDegrees")
    val rotation = number("rotationDegreesPerSecond")
    require(latitude in -MERCATOR_LATITUDE_LIMIT..MERCATOR_LATITUDE_LIMIT)
    require(longitude in -180.0..180.0)
    require(size > 0.0)
    return AnimatedCubeState(latitude, longitude, altitude, size, heading, rotation)
  }

  private fun readPaused(arguments: Map<*, *>): Boolean {
    val value = arguments["paused"]
    require(value is Boolean)
    return value
  }

  private fun attachRiggedModel(arguments: Map<*, *>, result: MethodChannel.Result) {
    fun number(key: String): Double {
      val value = arguments[key]
      require(value is Double && value.isFinite())
      return value
    }
    val bytes = arguments["glbBytes"]
    require(bytes is ByteArray)
    if (bytes.size > RiggedGlbLoader.MAX_BYTES) throw GlbException("GLB_TOO_LARGE")
    val latitude = number("latitude")
    val longitude = number("longitude")
    val altitude = number("altitudeMeters")
    val height = number("heightMeters")
    val heading = number("headingDegrees")
    val rate = number("playbackRate")
    val opacity = if (arguments.containsKey("opacity")) number("opacity").also { require(it in 0.0..1.0) } else 1.0
    val skinColor = readPaletteOverride(arguments, "skinColor")
    val eyeColor = readPaletteOverride(arguments, "eyeColor")
    val index = arguments["clipIndex"]
    require(index is Int || index is Long)
    val clipIndex = (index as Number).toLong()
    val nextPaused = readPaused(arguments)
    require(latitude in -MERCATOR_LATITUDE_LIMIT..MERCATOR_LATITUDE_LIMIT && longitude in -180.0..180.0)
    require(height > 0.0 && rate in 0.0..4.0 && clipIndex in 0..Int.MAX_VALUE.toLong())
    cancelPendingLoad("LOAD_SUPERSEDED")
    modelRequested = true
    modelLoadError = null
    val generation = loadGeneration
    loadResult = result
    loadTask = loader.submit {
      var decoded: RiggedModelState? = null
      var failure: String? = null
      try {
        val model = RiggedGlbLoader.decode(bytes)
        if (clipIndex >= model.clips.size) throw GlbException("INVALID_ARGUMENTS")
        decoded = RiggedModelState(model, latitude, longitude, altitude, height, heading, clipIndex.toInt(), rate, opacity,
          skinColor ?: if (model.usesCustomizer) RiggedCustomizerTint.skinReference.copyOf() else riggedColor("#FFD1B0"),
          eyeColor ?: if (model.usesCustomizer) RiggedCustomizerTint.eyeReference.copyOf() else riggedColor("#874721"))
      } catch (error: GlbException) {
        failure = error.code
      } catch (_: RuntimeException) {
        failure = "GLB_INVALID"
      }
      val accepted = decoded
      val errorCode = failure
      mainHandler.post {
        if (disposed || generation != loadGeneration) return@post
        val response = loadResult ?: return@post
        loadResult = null
        loadTask = null
        if (errorCode != null || accepted == null) {
          val code = errorCode ?: "GLB_INVALID"
          modelLoadError = code
          response.error(code, "The GLB could not be decoded.", null)
          return@post
        }
        try {
          // No existing scene/model is replaced until CPU validation succeeds.
          removeLayer()
          cube.set(null)
          accepted.retainPhase(rigged.get())
          rigged.set(accepted)
          paused = nextPaused
          previousFrameNanos = 0L
          lastErrorCode = null
          modelLoadError = null
          installLayerIfNeeded()
          updateRepaint()
          mapboxMap.triggerRepaint()
          // Acknowledges CPU acceptance. Only diagnostics can prove GPU readiness.
          response.success(null)
        } catch (error: CubeStyleException) {
          lastErrorCode = error.code
          stopRepaint()
          response.error(error.code, "The native model layer could not be updated.", null)
        } catch (_: RuntimeException) {
          lastErrorCode = "STYLE_LAYER_ADD_FAILED"
          stopRepaint()
          response.error("STYLE_LAYER_ADD_FAILED", "The native model layer could not be added.", null)
        }
      }
    }
  }

  private fun cancelPendingLoad(code: String) {
    loadGeneration++
    loadTask?.cancel(true)
    loadTask = null
    loader.purge()
    loadResult?.error(code, "The native model load did not remain active.", null)
    loadResult = null
  }

  private fun updateRiggedModel(arguments: Map<*, *>) {
    val model = rigged.get() ?: throw GlbException("MODEL_NOT_ATTACHED")
    fun number(key: String): Double {
      val value = arguments[key]
      require(value is Double && value.isFinite())
      return value
    }
    val latitude = number("latitude")
    val longitude = number("longitude")
    val heading = number("headingDegrees")
    require(latitude in -MERCATOR_LATITUDE_LIMIT..MERCATOR_LATITUDE_LIMIT && longitude in -180.0..180.0)
    val clip = if (arguments.containsKey("clipIndex")) {
      val value = arguments["clipIndex"]
      require(value is Int || value is Long)
      val index = (value as Number).toLong()
      require(index in 0 until model.model.clips.size.toLong())
      index.toInt()
    } else null
    val rate = if (arguments.containsKey("playbackRate")) number("playbackRate").also { require(it in 0.0..4.0) } else null
    val opacity = if (arguments.containsKey("opacity")) number("opacity").also { require(it in 0.0..1.0) } else null
    val duration = if (arguments.containsKey("opacityTransitionMilliseconds")) {
      require(opacity != null)
      val value = arguments["opacityTransitionMilliseconds"]
      require(value is Int || value is Long)
      (value as Number).toLong().also { require(it in 0L..1000L) }
    } else 0L
    val skinColor = readPaletteOverride(arguments, "skinColor")
    val eyeColor = readPaletteOverride(arguments, "eyeColor")
    if (skinColor != null) model.skinColor.set(skinColor)
    if (eyeColor != null) model.eyeColor.set(eyeColor)
    if (model.update(latitude, longitude, heading, clip, rate, opacity, duration)) previousFrameNanos = 0L
    updateRepaint()
    mapboxMap.triggerRepaint()
  }

  private fun readPaletteOverride(arguments: Map<*, *>, key: String): FloatArray? {
    if (arguments.containsKey(key + "Linear")) {
      val values = arguments[key + "Linear"]
      require(values is List<*> && values.size == 3)
      return FloatArray(3) { index ->
        val value = values[index]
        require(value is Number && value.toDouble().isFinite() && value.toDouble() in 0.001..1.0)
        value.toFloat()
      }
    }
    if (!arguments.containsKey(key)) return null
    val value = arguments[key]
    require(value is String)
    return riggedColor(value)
  }

  private fun hasActiveProbe(): Boolean = cube.get() != null || rigged.get() != null

  private fun ownsCurrentStyleHost(): Boolean =
    host != null && ownedHostStyleGeneration == styleGeneration.get()

  private fun discardStaleHost() {
    if (host != null && (!mapboxMap.isStyleLoaded() || !ownsCurrentStyleHost())) {
      // The SDK releases the old style's GPU resources through deinitialize.
      // Never remove an ID from the replacement style using stale ownership.
      host = null
      ownedHostStyleGeneration = -1L
    }
  }

  private fun installLayerIfNeeded() {
    discardStaleHost()
    if (disposed || !hasActiveProbe() || !mapboxMap.isStyleLoaded()) return
    val style = mapboxMap.styleManager
    if (style.styleLayerExists(LAYER_ID)) {
      if (!ownsCurrentStyleHost()) throw CubeStyleException("STYLE_LAYER_ID_CONFLICT")
      return
    }
    val generation = styleGeneration.get()
    val model = rigged.get()
    val nextHost: ProbeGlesHost = if (model != null) RiggedModelLayerHost(rigged, model) else CubeCustomLayerHost(cube, renderedFrames)
    val added = style.addStyleCustomLayer(LAYER_ID, nextHost, null)
    if (added.isError) throw CubeStyleException("STYLE_LAYER_ADD_FAILED")
    host = nextHost
    ownedHostStyleGeneration = generation
    val positioned = style.setStyleLayerProperty(LAYER_ID, "slot", Value.valueOf("top"))
    if (positioned.isError) throw CubeStyleException("STYLE_LAYER_POSITION_FAILED")
    lastErrorCode = null
  }

  private fun removeLayer() {
    // A style may already contain this reserved ID. An attach conflict never
    // gives this controller ownership of that unrelated layer.
    discardStaleHost()
    if (!ownsCurrentStyleHost() || !mapboxMap.isStyleLoaded()) return
    val style = mapboxMap.styleManager
    if (style.styleLayerExists(LAYER_ID)) {
      val removed = style.removeStyleLayer(LAYER_ID)
      if (removed.isError) throw CubeStyleException("STYLE_LAYER_REMOVE_FAILED")
    }
    // GPU deletion belongs to CustomLayerHost.deinitialize, on the render thread.
    host = null
    ownedHostStyleGeneration = -1L
  }

  private fun canRepaint(): Boolean =
    !disposed && viewAttached && hasActiveProbe() &&
      (rigged.get()?.let { (!paused && it.playbackRate > 0.0) || it.needsPlacementFrame() || it.needsOpacityFrame() }
        ?: (!paused && (cube.get()?.rotationDegreesPerSecond ?: 0.0) != 0.0)) &&
      lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) == true &&
      ownsCurrentStyleHost() && host?.lastErrorCode?.get() == null && lastErrorCode == null &&
      mapboxMap.isStyleLoaded() && mapboxMap.styleManager.styleLayerExists(LAYER_ID)

  private fun updateRepaint() {
    if (canRepaint()) {
      if (!framePosted) {
        choreographer.postFrameCallback(frameCallback)
        framePosted = true
      }
    } else {
      stopRepaint()
    }
  }

  private fun stopRepaint() {
    if (framePosted) choreographer.removeFrameCallback(frameCallback)
    framePosted = false
    previousFrameNanos = 0L
  }

  private fun diagnostics(): Map<String, Any?> = mapOf(
    "protocolVersion" to PROTOCOL_VERSION,
    "backend" to "androidGLES",
    "attached" to (cube.get() != null),
    "paused" to paused,
    "styleLayerPresent" to mapboxMap.styleManager.styleLayerExists(LAYER_ID),
    "initialized" to (cube.get() != null && host is CubeCustomLayerHost && ownsCurrentStyleHost() && mapboxMap.isStyleLoaded() && host?.initialized?.get() == true),
    "repaintEnabled" to (cube.get() != null && host is CubeCustomLayerHost && canRepaint()),
    "renderedFrames" to renderedFrames.get(),
    "lastErrorCode" to (lastErrorCode ?: host?.lastErrorCode?.get()),
    "incomingGlErrorCode" to host?.incomingGlErrorCode?.get(),
    "supportsSkeletalAnimation" to false,
  )

  private fun riggedDiagnostics(): Map<String, Any?> {
    val state = rigged.get()
    val opacity = state?.opacitySnapshot()
    val modelHost = if (ownsCurrentStyleHost() && mapboxMap.isStyleLoaded()) host as? RiggedModelLayerHost else null
    return mapOf(
      "protocolVersion" to PROTOCOL_VERSION,
      "backend" to "androidGLES",
      "requested" to modelRequested,
      "ready" to (state != null && modelHost != null && modelHost.initialized.get() && modelHost.lastErrorCode.get() == null),
      "paused" to paused,
      "repaintEnabled" to (state != null && canRepaint()),
      "renderedFrames" to (state?.renderedFrames?.get() ?: 0L),
      "poseRevision" to (state?.poseRevision?.get() ?: 0L),
      "animationTimeSeconds" to (state?.animationTimeSeconds ?: 0.0),
      "vertexCount" to (state?.model?.vertexCount ?: 0),
      "jointCount" to (state?.model?.jointNodes?.size ?: 0),
      "clipCount" to (state?.model?.clips?.size ?: 0),
      "clipIndex" to (state?.clipIndex ?: 0),
      "opacity" to opacity?.value,
      "targetOpacity" to opacity?.target,
      "isOpacityAnimating" to opacity?.isAnimating,
      "lastErrorCode" to (modelLoadError ?: lastErrorCode ?: modelHost?.lastErrorCode?.get()),
      "incomingGlErrorCode" to modelHost?.incomingGlErrorCode?.get(),
    )
  }

  fun dispose() {
    if (disposed) return
    disposed = true
    cancelPendingLoad("MAP_DISPOSED")
    loader.shutdownNow()
    cube.set(null)
    rigged.set(null)
    modelRequested = false
    stopRepaint()
    styleSubscription.cancel()
    lifecycle?.removeObserver(this)
    lifecycle = null
    channel.setMethodCallHandler(null)
    try {
      removeLayer()
    } catch (error: CubeStyleException) {
      lastErrorCode = error.code
    }
  }

  private class CubeStyleException(val code: String) : RuntimeException()

  private companion object {
    const val PROTOCOL_VERSION = 1
    const val LAYER_ID = "movey-animated-entities-p0-cube-v1"
    const val MERCATOR_LATITUDE_LIMIT = 85.05112878
  }
}

internal data class AnimatedCubeState(
  val latitude: Double,
  val longitude: Double,
  val altitudeMeters: Double,
  val sizeMeters: Double,
  val headingDegrees: Double,
  val rotationDegreesPerSecond: Double,
  val elapsedNanos: AtomicLong = AtomicLong(),
)
