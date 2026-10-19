package com.mapbox.maps.mapbox_maps

import android.view.Choreographer
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

/** Map-scoped native cube proof. This does not load models or animate skeletons. */
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
  private val renderedFrames = AtomicLong()
  private val choreographer = Choreographer.getInstance()
  private var host: CubeCustomLayerHost? = null
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
        cube.get()?.elapsedNanos?.addAndGet(frameTimeNanos - previousFrameNanos)
      }
      previousFrameNanos = frameTimeNanos
      mapboxMap.triggerRepaint()
      updateRepaint()
    }
  }

  init {
    channel.setMethodCallHandler(this)
    styleSubscription = mapboxMap.subscribeStyleLoaded {
      // Map/style work and Flutter channels stay on the Android main thread.
      mapView.post {
        if (!disposed && cube.get() != null) {
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
          lastErrorCode = null
          // A failed GPU initialization is retried only by an explicit attach.
          if (host?.lastErrorCode?.get() != null) removeLayer()
          host?.incomingGlErrorCode?.set(null)
          cube.set(nextCube)
          paused = nextPaused
          previousFrameNanos = 0L
          installLayerIfNeeded()
          updateRepaint()
          mapboxMap.triggerRepaint()
          result.success(null)
        }
        "setPaused" -> {
          paused = readPaused(arguments)
          updateRepaint()
          result.success(null)
        }
        "detach" -> {
          cube.set(null)
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

  private fun installLayerIfNeeded() {
    if (disposed || cube.get() == null || !mapboxMap.isStyleLoaded()) return
    val style = mapboxMap.styleManager
    if (style.styleLayerExists(LAYER_ID)) {
      if (host == null) throw CubeStyleException("STYLE_LAYER_ID_CONFLICT")
      return
    }
    val nextHost = CubeCustomLayerHost(cube, renderedFrames)
    val added = style.addStyleCustomLayer(LAYER_ID, nextHost, null)
    if (added.isError) throw CubeStyleException("STYLE_LAYER_ADD_FAILED")
    host = nextHost
    val positioned = style.setStyleLayerProperty(LAYER_ID, "slot", Value.valueOf("top"))
    if (positioned.isError) throw CubeStyleException("STYLE_LAYER_POSITION_FAILED")
    lastErrorCode = null
  }

  private fun removeLayer() {
    // A style may already contain this reserved ID. An attach conflict never
    // gives this controller ownership of that unrelated layer.
    if (host == null) return
    val style = mapboxMap.styleManager
    if (style.styleLayerExists(LAYER_ID)) {
      val removed = style.removeStyleLayer(LAYER_ID)
      if (removed.isError) throw CubeStyleException("STYLE_LAYER_REMOVE_FAILED")
    }
    // GPU deletion belongs to CustomLayerHost.deinitialize, on the render thread.
    host = null
  }

  private fun canRepaint(): Boolean =
    !disposed && viewAttached && !paused && cube.get() != null &&
      cube.get()?.rotationDegreesPerSecond != 0.0 &&
      lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) == true &&
      host != null && host?.lastErrorCode?.get() == null && lastErrorCode == null &&
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
    "initialized" to (host?.initialized?.get() == true),
    "repaintEnabled" to canRepaint(),
    "renderedFrames" to renderedFrames.get(),
    "lastErrorCode" to (lastErrorCode ?: host?.lastErrorCode?.get()),
    "incomingGlErrorCode" to host?.incomingGlErrorCode?.get(),
    "supportsSkeletalAnimation" to false,
  )

  fun dispose() {
    if (disposed) return
    disposed = true
    cube.set(null)
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
