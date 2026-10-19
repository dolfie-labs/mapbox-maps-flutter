package com.mapbox.maps.mapbox_maps

import android.opengl.GLES20
import android.opengl.GLES30
import android.util.Log
import com.mapbox.maps.CustomLayerHost
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Shared context/resource checks for both experimental native probes. */
internal abstract class ProbeGlesHost(private val logTag: String = "MoveyCubeProbe", capturesTextureState: Boolean = false, capturesBlendState: Boolean = false) : CustomLayerHost {
  val initialized = AtomicBoolean(false)
  val lastErrorCode = AtomicReference<String?>(null)
  val incomingGlErrorCode = AtomicReference<String?>(null)
  private val previousGlState = GlState(capturesTextureState, capturesBlendState)

  protected fun createProgram(vertexSource: String, fragmentSource: String, attributes: List<String>): Int {
    var vertexShader = 0
    var fragmentShader = 0
    var linkedProgram = 0
    try {
      vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSource)
      fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
      linkedProgram = GLES20.glCreateProgram()
      checkGpu(linkedProgram != 0, "GLES_PROGRAM_CREATION_FAILED")
      GLES20.glAttachShader(linkedProgram, vertexShader)
      GLES20.glAttachShader(linkedProgram, fragmentShader)
      for ((index, attribute) in attributes.withIndex()) GLES20.glBindAttribLocation(linkedProgram, index, attribute)
      GLES20.glLinkProgram(linkedProgram)
      val status = IntArray(1)
      GLES20.glGetProgramiv(linkedProgram, GLES20.GL_LINK_STATUS, status, 0)
      checkGpu(status[0] == GLES20.GL_TRUE, "GLES_PROGRAM_LINK_FAILED")
      return linkedProgram
    } catch (error: RuntimeException) {
      if (linkedProgram != 0) GLES20.glDeleteProgram(linkedProgram)
      throw error
    } finally {
      if (vertexShader != 0) GLES20.glDeleteShader(vertexShader)
      if (fragmentShader != 0) GLES20.glDeleteShader(fragmentShader)
    }
  }

  private fun compileShader(type: Int, source: String): Int {
    val shader = GLES20.glCreateShader(type)
    checkGpu(shader != 0, "GLES_SHADER_CREATION_FAILED")
    GLES20.glShaderSource(shader, source)
    GLES20.glCompileShader(shader)
    val status = IntArray(1)
    GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
    if (status[0] != GLES20.GL_TRUE) {
      GLES20.glDeleteShader(shader)
      throw GpuException("GLES_SHADER_COMPILE_FAILED")
    }
    return shader
  }

  protected fun checkGpu(condition: Boolean, code: String) {
    if (!condition) throw GpuException(code)
  }

  protected fun checkGl(stage: String) {
    val error = GLES20.glGetError()
    if (error != GLES20.GL_NO_ERROR) throw GpuException("GLES_${stage}_ERROR_$error")
  }

  protected fun observeIncomingGlError(stage: String) {
    // Mapbox shares its context and can enter this callback with an existing
    // error flag. Read one flag at the boundary before issuing our own GL calls;
    // retain it visibly without attributing it to this renderer's resources.
    val error = GLES20.glGetError()
    if (error == GLES20.GL_NO_ERROR) return
    val code = when (error) {
      GLES20.GL_INVALID_ENUM -> "GL_INVALID_ENUM"
      GLES20.GL_INVALID_VALUE -> "GL_INVALID_VALUE"
      GLES20.GL_INVALID_OPERATION -> "GL_INVALID_OPERATION"
      GLES20.GL_INVALID_FRAMEBUFFER_OPERATION -> "GL_INVALID_FRAMEBUFFER_OPERATION"
      GLES20.GL_OUT_OF_MEMORY -> "GL_OUT_OF_MEMORY"
      else -> "GL_ERROR_$error"
    }
    if (incomingGlErrorCode.getAndSet(code) != code) {
      Log.w(logTag, "inherited GL error at $stage: $code")
    }
  }

  protected fun captureGlState(stage: String): Boolean {
    try {
      previousGlState.capture()
      checkGl(stage)
      return true
    } catch (error: GpuException) {
      recordFailure(error.code)
    } catch (error: RuntimeException) {
      recordFailure("GLES_${stage}_EXCEPTION_${error.javaClass.simpleName}")
    }
    return false
  }

  protected fun restoreGlState() {
    try {
      previousGlState.restore()
      checkGl("STATE_RESTORE")
    } catch (error: GpuException) {
      recordFailure(error.code)
    } catch (error: RuntimeException) {
      recordFailure("GLES_STATE_RESTORE_EXCEPTION_${error.javaClass.simpleName}")
    }
  }

  protected fun recordFailure(code: String) {
    lastErrorCode.compareAndSet(null, code)
    Log.e(logTag, "owned GL failure: $code")
  }

  protected class GpuException(val code: String) : RuntimeException()

  /** Only the state changed by this layer is captured; Mapbox owns framebuffer/viewport. */
  private class GlState(private val capturesTextureState: Boolean, private val capturesBlendState: Boolean) {
    private val program = IntArray(1)
    private val arrayBuffer = IntArray(1)
    private val vertexArray = IntArray(1)
    private val depthFunction = IntArray(1)
    private val depthRange = FloatArray(2)
    private val depthWrite = BooleanArray(1)
    private val colorWrite = BooleanArray(4)
    private var depthTest = false
    private var stencilTest = false
    private var cullFace = false
    private var blend = false
    private val blendSourceRgb = IntArray(1)
    private val blendDestinationRgb = IntArray(1)
    private val blendSourceAlpha = IntArray(1)
    private val blendDestinationAlpha = IntArray(1)
    private val blendEquationRgb = IntArray(1)
    private val blendEquationAlpha = IntArray(1)
    private val activeTexture = IntArray(1)
    private val texture0 = IntArray(1)
    private val sampler0 = IntArray(1)
    private val unpackBuffer = IntArray(1)
    private val unpackAlignment = IntArray(1)
    private val unpackRowLength = IntArray(1)
    private val unpackSkipRows = IntArray(1)
    private val unpackSkipPixels = IntArray(1)

    fun capture() {
      GLES20.glGetIntegerv(GLES20.GL_CURRENT_PROGRAM, program, 0)
      GLES20.glGetIntegerv(GLES20.GL_ARRAY_BUFFER_BINDING, arrayBuffer, 0)
      GLES20.glGetIntegerv(GLES30.GL_VERTEX_ARRAY_BINDING, vertexArray, 0)
      GLES20.glGetIntegerv(GLES20.GL_DEPTH_FUNC, depthFunction, 0)
      GLES20.glGetFloatv(GLES20.GL_DEPTH_RANGE, depthRange, 0)
      GLES20.glGetBooleanv(GLES20.GL_DEPTH_WRITEMASK, depthWrite, 0)
      GLES20.glGetBooleanv(GLES20.GL_COLOR_WRITEMASK, colorWrite, 0)
      depthTest = GLES20.glIsEnabled(GLES20.GL_DEPTH_TEST)
      stencilTest = GLES20.glIsEnabled(GLES20.GL_STENCIL_TEST)
      cullFace = GLES20.glIsEnabled(GLES20.GL_CULL_FACE)
      blend = GLES20.glIsEnabled(GLES20.GL_BLEND)
      if (capturesBlendState) {
        GLES20.glGetIntegerv(GLES20.GL_BLEND_SRC_RGB, blendSourceRgb, 0)
        GLES20.glGetIntegerv(GLES20.GL_BLEND_DST_RGB, blendDestinationRgb, 0)
        GLES20.glGetIntegerv(GLES20.GL_BLEND_SRC_ALPHA, blendSourceAlpha, 0)
        GLES20.glGetIntegerv(GLES20.GL_BLEND_DST_ALPHA, blendDestinationAlpha, 0)
        GLES20.glGetIntegerv(GLES20.GL_BLEND_EQUATION_RGB, blendEquationRgb, 0)
        GLES20.glGetIntegerv(GLES20.GL_BLEND_EQUATION_ALPHA, blendEquationAlpha, 0)
      }
      if (capturesTextureState) {
        GLES20.glGetIntegerv(GLES20.GL_ACTIVE_TEXTURE, activeTexture, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glGetIntegerv(GLES20.GL_TEXTURE_BINDING_2D, texture0, 0)
        GLES20.glGetIntegerv(GLES30.GL_SAMPLER_BINDING, sampler0, 0)
        GLES20.glGetIntegerv(GLES30.GL_PIXEL_UNPACK_BUFFER_BINDING, unpackBuffer, 0)
        GLES20.glGetIntegerv(GLES20.GL_UNPACK_ALIGNMENT, unpackAlignment, 0)
        GLES20.glGetIntegerv(GLES30.GL_UNPACK_ROW_LENGTH, unpackRowLength, 0)
        GLES20.glGetIntegerv(GLES30.GL_UNPACK_SKIP_ROWS, unpackSkipRows, 0)
        GLES20.glGetIntegerv(GLES30.GL_UNPACK_SKIP_PIXELS, unpackSkipPixels, 0)
        GLES20.glActiveTexture(activeTexture[0])
      }
    }

    fun restore() {
      GLES20.glUseProgram(program[0])
      GLES30.glBindVertexArray(vertexArray[0])
      GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, arrayBuffer[0])
      GLES20.glDepthFunc(depthFunction[0])
      GLES20.glDepthMask(depthWrite[0])
      GLES20.glDepthRangef(depthRange[0], depthRange[1])
      GLES20.glColorMask(colorWrite[0], colorWrite[1], colorWrite[2], colorWrite[3])
      restoreFlag(GLES20.GL_DEPTH_TEST, depthTest)
      restoreFlag(GLES20.GL_STENCIL_TEST, stencilTest)
      restoreFlag(GLES20.GL_CULL_FACE, cullFace)
      restoreFlag(GLES20.GL_BLEND, blend)
      if (capturesBlendState) {
        GLES20.glBlendEquationSeparate(blendEquationRgb[0], blendEquationAlpha[0])
        GLES20.glBlendFuncSeparate(blendSourceRgb[0], blendDestinationRgb[0], blendSourceAlpha[0], blendDestinationAlpha[0])
      }
      if (capturesTextureState) {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture0[0])
        GLES30.glBindSampler(0, sampler0[0])
        GLES20.glBindBuffer(GLES30.GL_PIXEL_UNPACK_BUFFER, unpackBuffer[0])
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, unpackAlignment[0])
        GLES20.glPixelStorei(GLES30.GL_UNPACK_ROW_LENGTH, unpackRowLength[0])
        GLES20.glPixelStorei(GLES30.GL_UNPACK_SKIP_ROWS, unpackSkipRows[0])
        GLES20.glPixelStorei(GLES30.GL_UNPACK_SKIP_PIXELS, unpackSkipPixels[0])
        GLES20.glActiveTexture(activeTexture[0])
      }
    }

    private fun restoreFlag(flag: Int, enabled: Boolean) {
      if (enabled) GLES20.glEnable(flag) else GLES20.glDisable(flag)
    }
  }

}
