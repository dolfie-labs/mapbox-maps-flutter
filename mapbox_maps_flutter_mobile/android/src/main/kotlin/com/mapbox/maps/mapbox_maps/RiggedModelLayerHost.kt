package com.mapbox.maps.mapbox_maps

import android.opengl.GLES20
import android.opengl.GLES30
import com.mapbox.geojson.Point
import com.mapbox.maps.CustomLayerRenderParameters
import com.mapbox.maps.Projection
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

internal class RiggedModelState(
  val model: RiggedGlbModel,
  latitude: Double,
  longitude: Double,
  val altitudeMeters: Double,
  val heightMeters: Double,
  headingDegrees: Double,
  clipIndex: Int,
  playbackRate: Double,
  initialOpacity: Double = 1.0,
) {
  val renderedFrames = AtomicLong()
  val poseRevision = AtomicLong()
  val evaluator = RiggedPoseEvaluator(model)
  private val playback = AtomicReference(RiggedPlayback(clipIndex, playbackRate, 0.0))
  private val opacity = RiggedOpacity(initialOpacity)
  private val initialPlacement = RiggedPlacement(latitude, longitude, normalizeHeading(headingDegrees))
  private val placement = AtomicReference(RiggedPlacementTransition(initialPlacement, initialPlacement, 0L))
  private val settledPlacement = AtomicReference(placement.get())
  val clipIndex get() = playback.get().clipIndex
  val playbackRate get() = playback.get().rate
  val animationTimeSeconds get() = playback.get().seconds

  fun playbackSnapshot(): RiggedPlayback = playback.get()

  fun advanceAnimation(deltaNanos: Long) {
    while (true) {
      val previous = playback.get()
      val seconds = (previous.seconds + deltaNanos.toDouble() / 1_000_000_000.0 * previous.rate) % model.clips[previous.clipIndex].duration
      if (playback.compareAndSet(previous, previous.copy(seconds = seconds))) return
    }
  }

  /** Main-thread command, with atomic publication to Mapbox's render thread. */
  fun update(latitude: Double, longitude: Double, heading: Double, clip: Int?, rate: Double?, nextOpacity: Double? = null, opacityTransitionMilliseconds: Long = 0L): Boolean {
    val now = System.nanoTime()
    val wasHidden = opacity.snapshot(now).hidden
    val previous = playback.get()
    val nextClip = clip ?: previous.clipIndex
    val changedClip = nextClip != previous.clipIndex
    playback.set(RiggedPlayback(nextClip, rate ?: previous.rate, if (changedClip) 0.0 else previous.seconds))
    val target = RiggedPlacement(latitude, longitude, normalizeHeading(heading))
    val previousPlacement = placement.get()
    if (wasHidden) {
      val snapped = RiggedPlacementTransition(target, target, 0L)
      placement.set(snapped)
      settledPlacement.set(snapped)
    } else if (target != previousPlacement.to) {
      placement.set(RiggedPlacementTransition(previousPlacement.sample(now), target, now))
    }
    if (nextOpacity != null) opacity.update(nextOpacity, opacityTransitionMilliseconds, now)
    return changedClip
  }

  fun opacitySnapshot(now: Long = System.nanoTime()): RiggedOpacitySnapshot = opacity.snapshot(now)
  fun sampleOpacity(now: Long): Double = opacity.sample(now)
  fun needsOpacityFrame(): Boolean = opacity.needsFrame()

  fun settleHiddenPlacement() {
    val current = placement.get()
    val snapped = RiggedPlacementTransition(current.to, current.to, 0L)
    if (placement.compareAndSet(current, snapped)) settledPlacement.set(snapped)
  }

  fun needsPlacementFrame(): Boolean = settledPlacement.get() !== placement.get()

  fun samplePlacement(now: Long): RiggedPlacement {
    val transition = placement.get()
    val sampled = transition.sample(now)
    if (now - transition.startedNanos >= PLACEMENT_DURATION_NANOS) settledPlacement.set(transition)
    return sampled
  }

  private companion object {
    fun normalizeHeading(value: Double): Double = ((value % 360.0) + 360.0) % 360.0
  }
}

internal data class RiggedPlayback(val clipIndex: Int, val rate: Double, val seconds: Double)
internal data class RiggedPlacement(val latitude: Double, val longitude: Double, val headingDegrees: Double)
private const val PLACEMENT_DURATION_NANOS = 500_000_000L
private data class RiggedPlacementTransition(val from: RiggedPlacement, val to: RiggedPlacement, val startedNanos: Long) {
  fun sample(now: Long): RiggedPlacement {
    if (startedNanos == 0L) return to
    val fraction = ((now - startedNanos).toDouble() / PLACEMENT_DURATION_NANOS).coerceIn(0.0, 1.0)
    val longitude = from.longitude + shortestArc(to.longitude - from.longitude) * fraction
    return RiggedPlacement(
      from.latitude + (to.latitude - from.latitude) * fraction,
      ((longitude + 540.0) % 360.0) - 180.0,
      ((from.headingDegrees + shortestArc(to.headingDegrees - from.headingDegrees) * fraction) % 360.0 + 360.0) % 360.0,
    )
  }
  private fun shortestArc(value: Double): Double = ((value + 540.0) % 360.0) - 180.0
}

/** One real skinned mesh in Mapbox's render pass; no model/viewer surface. */
internal class RiggedModelLayerHost(
  private val active: AtomicReference<RiggedModelState?>,
  private val state: RiggedModelState,
) : ProbeGlesHost("MoveyRiggedProbe", capturesTextureState = true, capturesBlendState = true) {
  private var program = 0
  private val buffers = IntArray(2)
  private val vertexArray = IntArray(1)
  private val textures = IntArray(1)
  private var matrixLocation = -1
  private var jointsLocation = -1
  private var colorLocation = -1
  private var textureLocation = -1
  private var opacityLocation = -1
  private val modelMatrix = DoubleArray(16)
  private val finalMatrix = FloatArray(16)

  override fun initialize() {
    initialized.set(false)
    lastErrorCode.set(null)
    if (active.get() !== state) return
    observeIncomingGlError("initialize")
    if (!captureGlState("STATE_CAPTURE")) return
    try {
      program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER, listOf("a_position", "a_joints", "a_weights", "a_texcoord"))
      checkGl("PROGRAM")
      matrixLocation = GLES20.glGetUniformLocation(program, "u_matrix")
      jointsLocation = GLES20.glGetUniformLocation(program, "u_joints[0]")
      colorLocation = GLES20.glGetUniformLocation(program, "u_color")
      textureLocation = GLES20.glGetUniformLocation(program, "u_texture")
      opacityLocation = GLES20.glGetUniformLocation(program, "u_opacity")
      checkGpu(matrixLocation >= 0 && jointsLocation >= 0 && colorLocation >= 0 && textureLocation >= 0 && opacityLocation >= 0, "GLES_SHADER_INTERFACE_INVALID")
      GLES20.glGenBuffers(2, buffers, 0)
      GLES30.glGenVertexArrays(1, vertexArray, 0)
      checkGpu(buffers.all { it != 0 } && vertexArray[0] != 0, "GLES_BUFFER_CREATION_FAILED")
      checkGl("BUFFER_ALLOCATION")
      val model = state.model
      val vertices = ByteBuffer.allocateDirect(model.vertexCount * STRIDE).order(ByteOrder.nativeOrder()).asFloatBuffer()
      for (vertex in 0 until model.vertexCount) {
        vertices.put(model.positions, vertex * 3, 3)
        for (axis in 0..3) vertices.put(model.joints[vertex * 4 + axis].toFloat())
        vertices.put(model.weights, vertex * 4, 4)
        vertices.put(model.texCoords, vertex * 2, 2)
      }
      vertices.position(0)
      val indices = ByteBuffer.allocateDirect(model.indices.size * Int.SIZE_BYTES).order(ByteOrder.nativeOrder()).asIntBuffer()
      indices.put(model.indices).position(0)
      GLES30.glBindVertexArray(vertexArray[0])
      GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, buffers[0])
      GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, model.vertexCount * STRIDE, vertices, GLES20.GL_STATIC_DRAW)
      GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, buffers[1])
      GLES20.glBufferData(GLES20.GL_ELEMENT_ARRAY_BUFFER, model.indices.size * Int.SIZE_BYTES, indices, GLES20.GL_STATIC_DRAW)
      checkGl("BUFFER_UPLOAD")
      GLES20.glEnableVertexAttribArray(0)
      GLES20.glVertexAttribPointer(0, 3, GLES20.GL_FLOAT, false, STRIDE, 0)
      GLES20.glEnableVertexAttribArray(1)
      GLES20.glVertexAttribPointer(1, 4, GLES20.GL_FLOAT, false, STRIDE, 3 * Float.SIZE_BYTES)
      GLES20.glEnableVertexAttribArray(2)
      GLES20.glVertexAttribPointer(2, 4, GLES20.GL_FLOAT, false, STRIDE, 7 * Float.SIZE_BYTES)
      GLES20.glEnableVertexAttribArray(3)
      GLES20.glVertexAttribPointer(3, 2, GLES20.GL_FLOAT, false, STRIDE, 11 * Float.SIZE_BYTES)
      checkGl("VERTEX_ATTRIBUTES")
      uploadTexture(model.texture)
      initialized.set(true)
    } catch (error: GpuException) {
      recordFailure(error.code)
      deleteResources()
    } catch (error: RuntimeException) {
      recordFailure("GLES_MODEL_INIT_EXCEPTION_${error.javaClass.simpleName}")
      deleteResources()
    } finally {
      restoreGlState()
      if (lastErrorCode.get() != null) initialized.set(false)
    }
  }

  override fun render(parameters: CustomLayerRenderParameters) {
    if (active.get() !== state || !initialized.get() || lastErrorCode.get() != null) return
    val opacity = state.sampleOpacity(System.nanoTime())
    // Hidden preloads still initialize/upload above, but never draw or write depth.
    if (opacity == 0.0) {
      state.settleHiddenPlacement()
      return
    }
    observeIncomingGlError("render")
    try {
      val playback = state.playbackSnapshot()
      val clip = state.model.clips[playback.clipIndex]
      val time = playback.seconds
      if (state.evaluator.evaluate(clip, time)) state.poseRevision.incrementAndGet()
      if (!prepareMatrix(parameters)) return
    } catch (error: GlbException) {
      recordFailure(error.code)
      return
    } catch (error: RuntimeException) {
      recordFailure("POSE_EXCEPTION_${error.javaClass.simpleName}")
      return
    }
    if (!captureGlState("RENDER_STATE_CAPTURE")) return
    var drew = false
    try {
      GLES20.glEnable(GLES20.GL_DEPTH_TEST)
      GLES20.glDepthFunc(GLES20.GL_LESS)
      GLES20.glDepthMask(opacity == 1.0)
      GLES20.glDepthRangef(parameters.depthRange.min, parameters.depthRange.max)
      GLES20.glDisable(GLES20.GL_STENCIL_TEST)
      GLES20.glDisable(GLES20.GL_CULL_FACE)
      if (opacity < 1.0) {
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendEquationSeparate(GLES20.GL_FUNC_ADD, GLES20.GL_FUNC_ADD)
        GLES20.glBlendFuncSeparate(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA, GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA)
      } else {
        GLES20.glDisable(GLES20.GL_BLEND)
      }
      GLES20.glColorMask(true, true, true, true)
      GLES20.glUseProgram(program)
      GLES30.glBindVertexArray(vertexArray[0])
      GLES20.glUniformMatrix4fv(matrixLocation, 1, false, finalMatrix, 0)
      GLES20.glUniformMatrix4fv(jointsLocation, state.model.jointNodes.size, false, state.evaluator.palette, 0)
      GLES20.glUniform4fv(colorLocation, 1, state.model.color, 0)
      GLES20.glUniform1f(opacityLocation, opacity.toFloat())
      GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textures[0])
      GLES30.glBindSampler(0, 0)
      GLES20.glUniform1i(textureLocation, 0)
      GLES20.glDrawElements(GLES20.GL_TRIANGLES, state.model.indices.size, GLES20.GL_UNSIGNED_INT, 0)
      checkGl("SKINNED_DRAW")
      drew = true
    } catch (error: GpuException) {
      recordFailure(error.code)
    } catch (error: RuntimeException) {
      recordFailure("GLES_MODEL_DRAW_EXCEPTION_${error.javaClass.simpleName}")
    } finally {
      restoreGlState()
    }
    if (drew && lastErrorCode.get() == null) state.renderedFrames.incrementAndGet()
  }

  private fun prepareMatrix(parameters: CustomLayerRenderParameters): Boolean {
    val bounds = state.model.restBounds
    val placement = state.samplePlacement(System.nanoTime())
    val scale = state.heightMeters / bounds[3]
    val pixelsPerMeter = 1.0 / Projection.getMetersPerPixelAtLatitude(placement.latitude, parameters.zoom)
    val heightScale = Projection.getLatitudeScale(parameters.latitude) / Projection.getLatitudeScale(placement.latitude)
    val mercator = Projection.latLngToMercatorXY(Point.fromLngLat(placement.longitude, placement.latitude))
    val worldSize = Projection.worldSize(2.0.pow(parameters.zoom))
    val angle = (placement.headingDegrees % 360.0) * PI / 180.0
    val cosine = cos(angle)
    val sine = sin(angle)
    val xy = scale * pixelsPerMeter
    modelMatrix.fill(0.0)
    // glTF +X east, +Y up, +Z south; heading zero faces -Z (north).
    modelMatrix[0] = xy * cosine
    modelMatrix[1] = xy * sine
    modelMatrix[6] = scale * heightScale
    modelMatrix[8] = -xy * sine
    modelMatrix[9] = xy * cosine
    modelMatrix[12] = mercator.x * worldSize - bounds[0] * modelMatrix[0] - bounds[2] * modelMatrix[8]
    modelMatrix[13] = mercator.y * worldSize - bounds[0] * modelMatrix[1] - bounds[2] * modelMatrix[9]
    modelMatrix[14] = state.altitudeMeters * heightScale - bounds[1] * modelMatrix[6]
    modelMatrix[15] = 1.0
    if (modelMatrix.any { !it.isFinite() }) throw GlbException("MODEL_MATRIX_INVALID")
    val projected = parameters.projection.convertMercatorModelMatrix(modelMatrix.toList(), false) ?: return false
    val projection = parameters.projectionMatrix
    for (column in 0..3) for (row in 0..3) {
      var value = 0.0
      for (axis in 0..3) value += projection[axis * 4 + row] * projected[column * 4 + axis]
      finalMatrix[column * 4 + row] = value.toFloat()
    }
    if (finalMatrix.any { !it.isFinite() }) throw GlbException("PROJECTION_MATRIX_INVALID")
    return true
  }

  override fun contextLost() {
    initialized.set(false)
    program = 0
    buffers.fill(0)
    vertexArray[0] = 0
    textures[0] = 0
  }

  override fun deinitialize() { initialized.set(false); deleteResources() }

  private fun deleteResources() {
    if (vertexArray[0] != 0) GLES30.glDeleteVertexArrays(1, vertexArray, 0)
    GLES20.glDeleteBuffers(2, buffers, 0)
    GLES20.glDeleteTextures(1, textures, 0)
    if (program != 0) GLES20.glDeleteProgram(program)
    buffers.fill(0)
    vertexArray[0] = 0
    program = 0
    textures[0] = 0
  }

  private fun uploadTexture(texture: RigTexture?) {
    GLES20.glGenTextures(1, textures, 0)
    checkGpu(textures[0] != 0, "GLES_TEXTURE_CREATION_FAILED")
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textures[0])
    GLES30.glBindSampler(0, 0)
    GLES20.glBindBuffer(GLES30.GL_PIXEL_UNPACK_BUFFER, 0)
    GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 4)
    GLES20.glPixelStorei(GLES30.GL_UNPACK_ROW_LENGTH, 0)
    GLES20.glPixelStorei(GLES30.GL_UNPACK_SKIP_ROWS, 0)
    GLES20.glPixelStorei(GLES30.GL_UNPACK_SKIP_PIXELS, 0)
    val minFilter = texture?.minFilter ?: GLES20.GL_LINEAR
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, minFilter)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, texture?.magFilter ?: GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, texture?.wrapS ?: GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, texture?.wrapT ?: GLES20.GL_CLAMP_TO_EDGE)
    val rgba = texture?.rgba ?: byteArrayOf(-1, -1, -1, -1)
    val pixels = ByteBuffer.allocateDirect(rgba.size).order(ByteOrder.nativeOrder()).apply { put(rgba); position(0) }
    GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, texture?.width ?: 1, texture?.height ?: 1, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
    if (minFilter in GLES20.GL_NEAREST_MIPMAP_NEAREST..GLES20.GL_LINEAR_MIPMAP_LINEAR) GLES20.glGenerateMipmap(GLES20.GL_TEXTURE_2D)
    checkGl("TEXTURE_UPLOAD")
  }

  private companion object {
    const val STRIDE = 13 * Float.SIZE_BYTES
    val VERTEX_SHADER = """
      uniform mat4 u_matrix;
      uniform mat4 u_joints[32];
      attribute vec3 a_position;
      attribute vec4 a_joints;
      attribute vec4 a_weights;
      attribute vec2 a_texcoord;
      varying highp vec2 v_texcoord;
      void main() {
        mat4 skin = a_weights.x * u_joints[int(a_joints.x)]
                  + a_weights.y * u_joints[int(a_joints.y)]
                  + a_weights.z * u_joints[int(a_joints.z)]
                  + a_weights.w * u_joints[int(a_joints.w)];
        gl_Position = u_matrix * skin * vec4(a_position, 1.0);
        v_texcoord = a_texcoord;
      }
    """.trimIndent()
    // Intentional unlit base-color factor/texture subset; no PBR approximation.
    val FRAGMENT_SHADER = """
      precision mediump float;
      uniform vec4 u_color;
      uniform sampler2D u_texture;
      uniform float u_opacity;
      varying highp vec2 v_texcoord;
      void main() { gl_FragColor = vec4(u_color.rgb * texture2D(u_texture, v_texcoord).rgb, u_opacity); }
    """.trimIndent()
  }
}
