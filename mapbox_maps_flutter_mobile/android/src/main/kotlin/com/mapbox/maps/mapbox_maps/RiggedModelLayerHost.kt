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
  initialSkinColor: FloatArray = riggedColor("#FFD1B0"),
  initialEyeColor: FloatArray = riggedColor("#874721"),
) {
  val skinColor = AtomicReference(initialSkinColor)
  val eyeColor = AtomicReference(initialEyeColor)
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

  fun retainPhase(previous: RiggedModelState?) {
    if (previous == null || model.jointNodes.size != previous.model.jointNodes.size ||
        !model.inverseBind.contentEquals(previous.model.inverseBind)) return
    val before = previous.playbackSnapshot()
    val current = playback.get()
    if (before.clipIndex == current.clipIndex) {
      playback.set(current.copy(seconds = before.seconds % model.clips[current.clipIndex].duration))
    }
  }

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
  private val textures = IntArray(state.model.parts.size * 2)
  private val textureHandles = HashMap<Pair<RigTexture?, Boolean>, Int>()
  private var textureUploadBuffer: ByteBuffer? = null
  private var matrixLocation = -1
  private var jointsLocation = -1
  private var colorLocation = -1
  private var textureLocation = -1
  private var opacityLocation = -1
  private var maskLocation = -1
  private var skinLocation = -1
  private var eyeLocation = -1
  private var wholeSkinLocation = -1
  private var tintModeLocation = -1
  private val modelMatrix = DoubleArray(16)
  private val finalMatrix = FloatArray(16)

  override fun initialize() {
    initialized.set(false)
    lastErrorCode.set(null)
    if (active.get() !== state) return
    observeIncomingGlError("initialize")
    if (!captureGlState("STATE_CAPTURE")) return
    try {
      program = createProgram(VERTEX_SHADER.replace("u_joints[64]", "u_joints[${state.model.jointNodes.size}]"), FRAGMENT_SHADER, listOf("a_position", "a_joints", "a_weights", "a_texcoord"))
      checkGl("PROGRAM")
      matrixLocation = GLES20.glGetUniformLocation(program, "u_matrix")
      jointsLocation = GLES20.glGetUniformLocation(program, "u_joints[0]")
      colorLocation = GLES20.glGetUniformLocation(program, "u_color")
      textureLocation = GLES20.glGetUniformLocation(program, "u_texture")
      opacityLocation = GLES20.glGetUniformLocation(program, "u_opacity")
      maskLocation = GLES20.glGetUniformLocation(program, "u_mask")
      skinLocation = GLES20.glGetUniformLocation(program, "u_skin")
      eyeLocation = GLES20.glGetUniformLocation(program, "u_eye")
      wholeSkinLocation = GLES20.glGetUniformLocation(program, "u_wholeSkin")
      tintModeLocation = GLES20.glGetUniformLocation(program, "u_tintMode")
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
      val uploadCapacity = model.parts.maxOf { part ->
        maxOf((part.texture?.let { it.width * it.height * 4 } ?: 4),
          (part.mask?.let { it.width * it.height * 4 } ?: 4))
      }
      textureUploadBuffer = ByteBuffer.allocateDirect(uploadCapacity).order(ByteOrder.nativeOrder())
      for ((index, part) in model.parts.withIndex()) {
        uploadTexture(part.texture, index * 2, false)
        uploadTexture(part.mask, index * 2 + 1, true)
      }
      initialized.set(true)
    } catch (error: GpuException) {
      recordFailure(error.code)
      deleteResources()
    } catch (error: GlbException) {
      recordFailure("GLES_TEXTURE_DECODE_${error.code}")
      deleteResources()
    } catch (_: OutOfMemoryError) {
      recordFailure("GLES_TEXTURE_MEMORY_EXHAUSTED")
      deleteResources()
    } catch (error: RuntimeException) {
      recordFailure("GLES_MODEL_INIT_EXCEPTION_${error.javaClass.simpleName}")
      deleteResources()
    } finally {
      textureUploadBuffer = null
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
      GLES20.glUniform1f(opacityLocation, opacity.toFloat())
      GLES20.glUniform3fv(skinLocation, 1, state.skinColor.get(), 0)
      GLES20.glUniform3fv(eyeLocation, 1, state.eyeColor.get(), 0)
      GLES20.glUniform1i(textureLocation, 0)
      GLES20.glUniform1i(maskLocation, 1)
      for ((index, part) in state.model.parts.withIndex()) {
        GLES20.glUniform4fv(colorLocation, 1, part.color, 0)
        GLES20.glUniform1f(wholeSkinLocation, if (part.skin) 1f else 0f)
        GLES20.glUniform1f(tintModeLocation, part.tintMode.shaderValue)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textures[index * 2])
        GLES30.glBindSampler(0, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textures[index * 2 + 1])
        GLES30.glBindSampler(1, 0)
        GLES20.glDrawElements(GLES20.GL_TRIANGLES, part.indexCount, GLES20.GL_UNSIGNED_INT, part.firstIndex * Int.SIZE_BYTES)
      }
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
    textures.fill(0)
    textureHandles.clear()
    releaseTexturePixels()
  }

  override fun deinitialize() { initialized.set(false); deleteResources() }

  private fun deleteResources() {
    if (vertexArray[0] != 0) GLES30.glDeleteVertexArrays(1, vertexArray, 0)
    GLES20.glDeleteBuffers(2, buffers, 0)
    val uniqueTextures = textures.filter { it != 0 }.distinct().toIntArray()
    GLES20.glDeleteTextures(uniqueTextures.size, uniqueTextures, 0)
    if (program != 0) GLES20.glDeleteProgram(program)
    buffers.fill(0)
    vertexArray[0] = 0
    program = 0
    textures.fill(0)
    textureHandles.clear()
    releaseTexturePixels()
  }

  private fun releaseTexturePixels() {
    // Include parts not yet uploaded after initialization failure. The bounded
    // compressed sources remain available for a later host/context retry.
    for (part in state.model.parts) {
      part.texture?.releasePixels()
      part.mask?.releasePixels()
    }
  }

  private fun uploadTexture(texture: RigTexture?, index: Int, mask: Boolean) {
    val key = texture to (texture == null && mask)
    textureHandles[key]?.let { textures[index] = it; return }
    GLES20.glGenTextures(1, textures, index)
    checkGpu(textures[index] != 0, "GLES_TEXTURE_CREATION_FAILED")
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textures[index])
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
    val rgba = texture?.pixels() ?: if (mask) byteArrayOf(0, 0, 0, -1) else byteArrayOf(-1, -1, -1, -1)
    // glTexImage2D consumes the client bytes before returning; reuse one bounded
    // staging buffer across all materials instead of one direct allocation each.
    val pixels = checkNotNull(textureUploadBuffer).apply { clear(); put(rgba); flip() }
    GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, texture?.width ?: 1, texture?.height ?: 1, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
    if (minFilter in GLES20.GL_NEAREST_MIPMAP_NEAREST..GLES20.GL_LINEAR_MIPMAP_LINEAR) GLES20.glGenerateMipmap(GLES20.GL_TEXTURE_2D)
    checkGl("TEXTURE_UPLOAD")
    textureHandles[key] = textures[index]
    // GPU storage is now independent. Keep only the bounded compressed source
    // for future style/context recreation instead of retaining ~50 MiB/actor.
    texture?.releasePixels()
  }

  private companion object {
    const val STRIDE = 13 * Float.SIZE_BYTES
    val VERTEX_SHADER = """
      uniform mat4 u_matrix;
      uniform mat4 u_joints[64];
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
      precision highp float;
      uniform vec4 u_color;
      uniform sampler2D u_texture;
      uniform float u_opacity;
      uniform sampler2D u_mask;
      uniform vec3 u_skin;
      uniform vec3 u_eye;
      uniform float u_wholeSkin;
      uniform float u_tintMode;
      varying highp vec2 v_texcoord;
      vec3 linearColor(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c)); }
      vec3 srgbColor(vec3 c) { return mix(c * 12.92, 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c)); }
      vec3 customizerHsv(vec3 rgb) {
        float maximum = max(rgb.r, max(rgb.g, rgb.b)), minimum = min(rgb.r, min(rgb.g, rgb.b));
        float difference = maximum - minimum;
        if (difference <= 0.0) return vec3(0.0, 0.0, maximum);
        float hue;
        if (maximum == rgb.r) hue = (rgb.g - rgb.b) / difference + (rgb.g < rgb.b ? 6.0 : 0.0);
        else if (maximum == rgb.g) hue = (rgb.b - rgb.r) / difference + 2.0;
        else hue = (rgb.r - rgb.g) / difference + 4.0;
        return vec3(hue / 6.0, maximum > 0.0 ? difference / maximum : 0.0, maximum);
      }
      vec3 customizerRgb(vec3 hsv) {
        vec3 p = abs(fract(hsv.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
        return hsv.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), hsv.y);
      }
      float customizerLipValue(vec3 skin) {
        vec3 reference = vec3(0.88792324, 0.38132605, 0.1559265), luminance = vec3(0.2126, 0.7152, 0.0722);
        return clamp(sqrt(dot(skin, luminance) / dot(reference, luminance)), 0.2, 1.2);
      }
      vec3 customizerColor(vec3 base, vec3 mask, vec3 skin, vec3 eye) {
        vec3 result = mix(base, base * skin / vec3(0.88792324, 0.38132605, 0.1559265), mask.r);
        vec3 value = customizerHsv(result), target = customizerHsv(eye);
        vec3 reference = vec3(0.03481012658227848, 0.8777777777777778, 0.18);
        value.x = fract(value.x + target.x - reference.x);
        value.y = clamp(value.y * target.y / reference.y, 0.0, 1.0);
        value.z *= clamp(target.z / reference.z, 0.25, 1.4);
        result = mix(result, customizerRgb(value), mask.g);
        return max(result * (1.0 + mask.b * (customizerLipValue(skin) - 1.0)), vec3(0.0));
      }
      void main() {
        vec3 mask = texture2D(u_mask, v_texcoord).rgb;
        vec3 base = u_color.rgb * linearColor(texture2D(u_texture, v_texcoord).rgb);
        vec3 color;
        if (u_tintMode > 2.5) color = base * customizerLipValue(u_skin);
        else if (u_tintMode > 1.5) color = base * u_skin / vec3(0.88792324, 0.38132605, 0.1559265);
        else if (u_tintMode > 0.5) color = customizerColor(base, mask, u_skin, u_eye);
        else {
          mask = mix(mask, vec3(1.0, 0.0, 0.0), u_wholeSkin);
          mask /= max(1.0, mask.x + mask.y);
          vec3 tint = vec3(1.0 - mask.x - mask.y) + mask.x * u_skin + mask.y * u_eye;
          color = base * tint;
        }
        gl_FragColor = vec4(srgbColor(color), u_opacity);
      }
    """.trimIndent()
  }
}

/** Converts the legacy sRGB transport into the renderer's linear uniforms. */
internal fun riggedColor(value: String): FloatArray {
  require(Regex("#[0-9a-fA-F]{6}").matches(value))
  return FloatArray(3) {
    val srgb = value.substring(1 + it * 2, 3 + it * 2).toInt(16) / 255f
    if (srgb <= 0.04045f) srgb / 12.92f else ((srgb + 0.055f) / 1.055f).pow(2.4f)
  }
}
