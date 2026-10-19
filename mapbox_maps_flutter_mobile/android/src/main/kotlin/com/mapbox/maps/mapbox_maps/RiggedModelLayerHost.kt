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
  val latitude: Double,
  val longitude: Double,
  val altitudeMeters: Double,
  val heightMeters: Double,
  val headingDegrees: Double,
  val clipIndex: Int,
  val playbackRate: Double,
) {
  val elapsedNanos = AtomicLong()
  val renderedFrames = AtomicLong()
  val poseRevision = AtomicLong()
  val evaluator = RiggedPoseEvaluator(model)
  @Volatile var animationTimeSeconds = 0.0
}

/** One real skinned mesh in Mapbox's render pass; no model/viewer surface. */
internal class RiggedModelLayerHost(
  private val active: AtomicReference<RiggedModelState?>,
  private val state: RiggedModelState,
) : ProbeGlesHost("MoveyRiggedProbe") {
  private var program = 0
  private val buffers = IntArray(2)
  private val vertexArray = IntArray(1)
  private var matrixLocation = -1
  private var jointsLocation = -1
  private var colorLocation = -1
  private val modelMatrix = DoubleArray(16)
  private val finalMatrix = FloatArray(16)

  override fun initialize() {
    initialized.set(false)
    lastErrorCode.set(null)
    if (active.get() !== state) return
    observeIncomingGlError("initialize")
    if (!captureGlState("STATE_CAPTURE")) return
    try {
      program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER, listOf("a_position", "a_joints", "a_weights"))
      checkGl("PROGRAM")
      matrixLocation = GLES20.glGetUniformLocation(program, "u_matrix")
      jointsLocation = GLES20.glGetUniformLocation(program, "u_joints[0]")
      colorLocation = GLES20.glGetUniformLocation(program, "u_color")
      checkGpu(matrixLocation >= 0 && jointsLocation >= 0 && colorLocation >= 0, "GLES_SHADER_INTERFACE_INVALID")
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
      checkGl("VERTEX_ATTRIBUTES")
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
    observeIncomingGlError("render")
    try {
      val clip = state.model.clips[state.clipIndex]
      val time = (state.elapsedNanos.get().toDouble() / 1_000_000_000.0 * state.playbackRate) % clip.duration
      if (state.evaluator.evaluate(clip, time)) state.poseRevision.incrementAndGet()
      state.animationTimeSeconds = time
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
      GLES20.glDepthMask(true)
      GLES20.glDepthRangef(parameters.depthRange.min, parameters.depthRange.max)
      GLES20.glDisable(GLES20.GL_STENCIL_TEST)
      GLES20.glDisable(GLES20.GL_CULL_FACE)
      GLES20.glDisable(GLES20.GL_BLEND)
      GLES20.glColorMask(true, true, true, true)
      GLES20.glUseProgram(program)
      GLES30.glBindVertexArray(vertexArray[0])
      GLES20.glUniformMatrix4fv(matrixLocation, 1, false, finalMatrix, 0)
      GLES20.glUniformMatrix4fv(jointsLocation, state.model.jointNodes.size, false, state.evaluator.palette, 0)
      GLES20.glUniform4fv(colorLocation, 1, state.model.color, 0)
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
    val scale = state.heightMeters / bounds[3]
    val pixelsPerMeter = 1.0 / Projection.getMetersPerPixelAtLatitude(state.latitude, parameters.zoom)
    val heightScale = Projection.getLatitudeScale(parameters.latitude) / Projection.getLatitudeScale(state.latitude)
    val mercator = Projection.latLngToMercatorXY(Point.fromLngLat(state.longitude, state.latitude))
    val worldSize = Projection.worldSize(2.0.pow(parameters.zoom))
    val angle = (state.headingDegrees % 360.0) * PI / 180.0
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
  }

  override fun deinitialize() { initialized.set(false); deleteResources() }

  private fun deleteResources() {
    if (vertexArray[0] != 0) GLES30.glDeleteVertexArrays(1, vertexArray, 0)
    GLES20.glDeleteBuffers(2, buffers, 0)
    if (program != 0) GLES20.glDeleteProgram(program)
    buffers.fill(0)
    vertexArray[0] = 0
    program = 0
  }

  private companion object {
    const val STRIDE = 11 * Float.SIZE_BYTES
    val VERTEX_SHADER = """
      uniform mat4 u_matrix;
      uniform mat4 u_joints[32];
      attribute vec3 a_position;
      attribute vec4 a_joints;
      attribute vec4 a_weights;
      void main() {
        mat4 skin = a_weights.x * u_joints[int(a_joints.x)]
                  + a_weights.y * u_joints[int(a_joints.y)]
                  + a_weights.z * u_joints[int(a_joints.z)]
                  + a_weights.w * u_joints[int(a_joints.w)];
        gl_Position = u_matrix * skin * vec4(a_position, 1.0);
      }
    """.trimIndent()
    // Intentional unlit base-color subset, including no texture/PBR approximation.
    val FRAGMENT_SHADER = """
      precision mediump float;
      uniform vec4 u_color;
      void main() { gl_FragColor = vec4(u_color.rgb, 1.0); }
    """.trimIndent()
  }
}
