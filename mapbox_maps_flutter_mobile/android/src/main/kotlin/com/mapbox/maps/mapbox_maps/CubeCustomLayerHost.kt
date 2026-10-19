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
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

/** A geographic cube rendered in Mapbox's GLES pass, with no separate surface. */
internal class CubeCustomLayerHost(
  private val cube: AtomicReference<AnimatedCubeState?>,
  private val renderedFrames: AtomicLong,
) : ProbeGlesHost() {

  private var program = 0
  private val vertexBuffer = IntArray(1)
  private val vertexArray = IntArray(1)
  private var matrixLocation = -1
  private val modelMatrix = DoubleArray(16)
  private val finalMatrix = FloatArray(16)

  override fun initialize() {
    initialized.set(false)
    lastErrorCode.set(null)
    observeIncomingGlError("initialize")
    if (!captureGlState("STATE_CAPTURE")) return
    var stage = "PROGRAM"
    try {
      program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER, listOf("a_position", "a_color"))
      checkGl("PROGRAM")
      matrixLocation = GLES20.glGetUniformLocation(program, "u_matrix")
      checkGpu(matrixLocation >= 0, "GLES_SHADER_INTERFACE_INVALID")
      stage = "BUFFER_ALLOCATION"
      GLES20.glGenBuffers(1, vertexBuffer, 0)
      GLES30.glGenVertexArrays(1, vertexArray, 0)
      checkGpu(vertexBuffer[0] != 0 && vertexArray[0] != 0, "GLES_BUFFER_CREATION_FAILED")
      checkGl(stage)

      val vertices = cubeVertices()
      val data = ByteBuffer.allocateDirect(vertices.size * Float.SIZE_BYTES)
        .order(ByteOrder.nativeOrder()).asFloatBuffer()
      data.put(vertices).position(0)

      stage = "BUFFER_UPLOAD"
      GLES30.glBindVertexArray(vertexArray[0])
      GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vertexBuffer[0])
      GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, vertices.size * Float.SIZE_BYTES, data, GLES20.GL_STATIC_DRAW)
      checkGl(stage)
      stage = "VERTEX_ATTRIBUTES"
      GLES20.glEnableVertexAttribArray(0)
      GLES20.glVertexAttribPointer(0, 3, GLES20.GL_FLOAT, false, VERTEX_STRIDE, 0)
      GLES20.glEnableVertexAttribArray(1)
      GLES20.glVertexAttribPointer(1, 3, GLES20.GL_FLOAT, false, VERTEX_STRIDE, 3 * Float.SIZE_BYTES)
      checkGl(stage)
      initialized.set(true)
    } catch (error: GpuException) {
      recordFailure(error.code)
      deleteGpuResources()
    } catch (error: RuntimeException) {
      recordFailure("GLES_${stage}_EXCEPTION_${error.javaClass.simpleName}")
      deleteGpuResources()
    } finally {
      restoreGlState()
      if (lastErrorCode.get() != null) initialized.set(false)
    }
  }

  override fun render(parameters: CustomLayerRenderParameters) {
    if (!initialized.get() || lastErrorCode.get() != null) return
    val state = cube.get() ?: return
    observeIncomingGlError("render")
    if (!prepareMatrix(parameters, state)) return

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
      GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, VERTEX_COUNT)
      checkGl("DRAW")
      drew = true
    } catch (error: GpuException) {
      recordFailure(error.code)
    } catch (error: RuntimeException) {
      recordFailure("GLES_DRAW_EXCEPTION_${error.javaClass.simpleName}")
    } finally {
      restoreGlState()
    }
    if (drew && lastErrorCode.get() == null) renderedFrames.incrementAndGet()
  }

  private fun prepareMatrix(parameters: CustomLayerRenderParameters, state: AnimatedCubeState): Boolean {
    val location = Point.fromLngLat(state.longitude, state.latitude)
    val mercator = Projection.latLngToMercatorXY(location)
    val worldSize = Projection.worldSize(2.0.pow(parameters.zoom))
    val pixelsPerMeter = 1.0 / Projection.getMetersPerPixelAtLatitude(state.latitude, parameters.zoom)
    val heightScale = Projection.getLatitudeScale(parameters.latitude) / Projection.getLatitudeScale(state.latitude)
    val sizeInPixels = state.sizeMeters * pixelsPerMeter

    val seconds = state.elapsedNanos.get().toDouble() / NANOS_PER_SECOND
    // Reduce time by the rotation period before multiplication, including for large finite speeds.
    val rotation = if (state.rotationDegreesPerSecond == 0.0) {
      0.0
    } else {
      (seconds % (360.0 / abs(state.rotationDegreesPerSecond))) * state.rotationDegreesPerSecond
    }
    val angle = ((state.headingDegrees % 360.0) + rotation) * PI / 180.0
    val cosine = cos(angle)
    val sine = sin(angle)
    modelMatrix.fill(0.0)
    // Mapbox's Mercator model frame is +X east, +Y south, +Z up.
    // Positive yaw turns the north-facing face clockwise toward east.
    modelMatrix[0] = sizeInPixels * cosine
    modelMatrix[1] = sizeInPixels * sine
    modelMatrix[4] = -sizeInPixels * sine
    modelMatrix[5] = sizeInPixels * cosine
    modelMatrix[10] = state.sizeMeters * heightScale
    modelMatrix[12] = mercator.x * worldSize
    modelMatrix[13] = mercator.y * worldSize
    modelMatrix[14] = state.altitudeMeters * heightScale
    modelMatrix[15] = 1.0
    if (modelMatrix.any { !it.isFinite() }) {
      recordFailure("MODEL_MATRIX_INVALID")
      return false
    }

    // This SDK helper also accounts for the current map projection. A null matrix
    // means the object cannot be projected in this frame (for example, behind the globe).
    val projectedModel = parameters.projection.convertMercatorModelMatrix(modelMatrix.toList(), false)
      ?: return false
    val projection = parameters.projectionMatrix
    for (column in 0..3) {
      for (row in 0..3) {
        var value = 0.0
        for (index in 0..3) {
          value += projection[index * 4 + row] * projectedModel[column * 4 + index]
        }
        finalMatrix[column * 4 + row] = value.toFloat()
      }
    }
    if (finalMatrix.any { !it.isFinite() }) {
      recordFailure("PROJECTION_MATRIX_INVALID")
      return false
    }
    return true
  }

  override fun contextLost() {
    // The context has already gone away; deleting its old numeric handles is invalid.
    initialized.set(false)
    program = 0
    vertexBuffer[0] = 0
    vertexArray[0] = 0
    matrixLocation = -1
  }

  override fun deinitialize() {
    initialized.set(false)
    deleteGpuResources()
  }

  private fun deleteGpuResources() {
    if (vertexArray[0] != 0) GLES30.glDeleteVertexArrays(1, vertexArray, 0)
    if (vertexBuffer[0] != 0) GLES20.glDeleteBuffers(1, vertexBuffer, 0)
    if (program != 0) GLES20.glDeleteProgram(program)
    vertexArray[0] = 0
    vertexBuffer[0] = 0
    program = 0
    matrixLocation = -1
  }

  private companion object {
    const val VERTEX_COUNT = 36
    const val VERTEX_STRIDE = 6 * Float.SIZE_BYTES
    const val NANOS_PER_SECOND = 1_000_000_000.0

    val VERTEX_SHADER = """
      uniform mat4 u_matrix;
      attribute vec3 a_position;
      attribute vec3 a_color;
      varying vec3 v_color;
      void main() {
        gl_Position = u_matrix * vec4(a_position, 1.0);
        v_color = a_color;
      }
    """.trimIndent()

    val FRAGMENT_SHADER = """
      precision mediump float;
      varying vec3 v_color;
      void main() {
        gl_FragColor = vec4(v_color, 1.0);
      }
    """.trimIndent()

    fun cubeVertices(): FloatArray {
      // Ground origin at z=0; the north face is red at heading zero.
      val corners = arrayOf(
        floatArrayOf(-0.5f, -0.5f, 0f), floatArrayOf(0.5f, -0.5f, 0f),
        floatArrayOf(0.5f, 0.5f, 0f), floatArrayOf(-0.5f, 0.5f, 0f),
        floatArrayOf(-0.5f, -0.5f, 1f), floatArrayOf(0.5f, -0.5f, 1f),
        floatArrayOf(0.5f, 0.5f, 1f), floatArrayOf(-0.5f, 0.5f, 1f),
      )
      val faces = arrayOf(
        intArrayOf(0, 1, 5, 0, 5, 4), intArrayOf(1, 2, 6, 1, 6, 5),
        intArrayOf(2, 3, 7, 2, 7, 6), intArrayOf(3, 0, 4, 3, 4, 7),
        intArrayOf(4, 5, 6, 4, 6, 7), intArrayOf(3, 2, 1, 3, 1, 0),
      )
      val colors = arrayOf(
        floatArrayOf(0.95f, 0.22f, 0.18f), floatArrayOf(0.18f, 0.72f, 0.95f),
        floatArrayOf(0.95f, 0.68f, 0.14f), floatArrayOf(0.32f, 0.80f, 0.35f),
        floatArrayOf(0.72f, 0.40f, 0.95f), floatArrayOf(0.25f, 0.28f, 0.34f),
      )
      val vertices = FloatArray(VERTEX_COUNT * 6)
      var offset = 0
      for (faceIndex in faces.indices) {
        for (cornerIndex in faces[faceIndex]) {
          for (value in corners[cornerIndex]) vertices[offset++] = value
          for (value in colors[faceIndex]) vertices[offset++] = value
        }
      }
      return vertices
    }
  }
}
