package com.mapbox.maps.mapbox_maps

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

internal class GlbException(val code: String) : RuntimeException()

/** Deliberately bounded glTF subset for the native skeletal proof. No external IO. */
internal object RiggedGlbLoader {
  const val MAX_BYTES = 8 * 1024 * 1024

  fun decode(bytes: ByteArray): RiggedGlbModel {
    if (bytes.size > MAX_BYTES) throw GlbException("GLB_TOO_LARGE")
    try {
      return Reader(bytes).read()
    } catch (error: GlbException) {
      if (error.code == "POSE_INVALID") throw GlbException("GLB_INVALID")
      throw error
    } catch (_: InterruptedException) {
      throw GlbException("LOAD_SUPERSEDED")
    } catch (_: JSONException) {
      throw GlbException("GLB_INVALID")
    } catch (_: java.nio.charset.CharacterCodingException) {
      throw GlbException("GLB_INVALID")
    } catch (_: ArithmeticException) {
      throw GlbException("GLB_INVALID")
    } catch (_: IndexOutOfBoundsException) {
      throw GlbException("GLB_INVALID")
    } catch (_: OutOfMemoryError) {
      throw GlbException("GLB_TOO_LARGE")
    }
  }

  private class Reader(private val bytes: ByteArray) {
    private lateinit var json: JSONObject
    private lateinit var binary: ByteBuffer
    private lateinit var views: JSONArray
    private lateinit var accessors: JSONArray
    private var binaryLength = 0
    private var copiedScalars = 0L
    private val textureCache = HashMap<Int, RigTexture>()
    private var decodedImagePixels = 0L

    fun read(): RiggedGlbModel {
      checkCancelled()
      invalid(bytes.size >= 28)
      val file = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
      invalid(file.int == 0x46546c67 && file.int == 2 && file.int == bytes.size)
      val jsonLength = file.int
      invalid(file.int == 0x4e4f534a && jsonLength > 0 && jsonLength <= 256 * 1024)
      invalid(jsonLength % 4 == 0 && jsonLength.toLong() + 20 <= bytes.size)
      val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes, 20, jsonLength)).toString()
      validateJsonDepth(text)
      json = JSONObject(text)
      validateExtensionsRecursively(json)
      if (json.has("cameras")) unsupported(json.getJSONArray("cameras").length() == 0)
      for (key in listOf("textures", "images", "samplers")) {
        if (json.has(key)) unsupported(json.getJSONArray(key).length() <= 16)
      }
      file.position(20 + jsonLength)
      invalid(file.remaining() >= 8)
      val binLength = file.int
      unsupported(file.int == 0x004e4942)
      invalid(binLength >= 0 && binLength % 4 == 0 && binLength == file.remaining())
      binary = file.slice().order(ByteOrder.LITTLE_ENDIAN)
      val asset = json.getJSONObject("asset")
      unsupported(asset.getString("version") == "2.0")
      rejectExtensions(json)
      val buffers = json.getJSONArray("buffers")
      unsupported(buffers.length() == 1)
      val buffer = buffers.getJSONObject(0)
      unsupported(!buffer.has("uri"))
      binaryLength = integer(buffer, "byteLength")
      invalid(binaryLength <= binLength && binLength - binaryLength <= 3)
      views = json.getJSONArray("bufferViews")
      accessors = json.getJSONArray("accessors")
      unsupported(views.length() in 1..1024 && accessors.length() in 1..1024)

      val nodeJson = json.getJSONArray("nodes")
      unsupported(nodeJson.length() in 1..128)
      val nodes = Array(nodeJson.length()) { index -> readNode(nodeJson.getJSONObject(index)) }
      val parents = IntArray(nodes.size) { -1 }
      for (parent in nodes.indices) {
        for (child in nodes[parent].children) {
          invalid(child in nodes.indices && child != parent && parents[child] == -1)
          parents[child] = parent
        }
      }
      val order = topologicalOrder(nodes, parents)
      val scenes = json.getJSONArray("scenes")
      unsupported(scenes.length() == 1 && integer(json, "scene", 0) == 0)
      val sceneRoots = intList(scenes.getJSONObject(0).getJSONArray("nodes"))
      invalid(sceneRoots.isNotEmpty() && sceneRoots.distinct().size == sceneRoots.size)
      val reachable = BooleanArray(nodes.size)
      fun visit(index: Int) {
        invalid(index in nodes.indices)
        reachable[index] = true
        for (child in nodes[index].children) visit(child)
      }
      for (index in sceneRoots) {
        invalid(index in nodes.indices && parents[index] == -1)
        visit(index)
      }

      val meshNodes = (0 until nodeJson.length()).filter { nodeJson.getJSONObject(it).has("mesh") }
      unsupported(meshNodes.size in 1..8)
      for (meshNode in meshNodes) {
        invalid(reachable[meshNode])
        unsupported(integer(nodeJson.getJSONObject(meshNode), "skin") == 0)
      }
      val skins = json.getJSONArray("skins")
      unsupported(skins.length() == 1)
      val skin = skins.getJSONObject(0)
      val jointNodes = intList(skin.getJSONArray("joints"))
      unsupported(jointNodes.size in 1..64)
      invalid(jointNodes.distinct().size == jointNodes.size)
      for (joint in jointNodes) invalid(joint in nodes.indices && reachable[joint])
      if (skin.has("skeleton")) invalid(integer(skin, "skeleton") in nodes.indices)
      val inverseBind = if (skin.has("inverseBindMatrices")) {
        floats(integer(skin, "inverseBindMatrices"), "MAT4", jointNodes.size)
      } else {
        FloatArray(jointNodes.size * 16).also { array ->
          for (joint in jointNodes.indices) for (axis in 0..3) array[joint * 16 + axis * 5] = 1f
        }
      }
      for (joint in jointNodes.indices) {
        val offset = joint * 16
        invalid(abs(inverseBind[offset + 3]) < 1e-6 && abs(inverseBind[offset + 7]) < 1e-6 &&
          abs(inverseBind[offset + 11]) < 1e-6 && abs(inverseBind[offset + 15] - 1f) < 1e-6)
      }
      val meshes = json.getJSONArray("meshes")
      unsupported(meshes.length() in 1..8)
      val allPositions = ArrayList<Float>(); val allJoints = ArrayList<Int>()
      val allWeights = ArrayList<Float>(); val allTexCoords = ArrayList<Float>()
      val allIndices = ArrayList<Int>(); val parts = ArrayList<RigPart>()
      for (meshNode in meshNodes) {
        val meshIndex = integer(nodeJson.getJSONObject(meshNode), "mesh")
        invalid(meshIndex in 0 until meshes.length())
        val mesh = meshes.getJSONObject(meshIndex)
        unsupported(!mesh.has("weights"))
        val primitives = mesh.getJSONArray("primitives")
        unsupported(primitives.length() in 1..16)
        for (primitiveIndex in 0 until primitives.length()) {
          unsupported(parts.size < 16)
          val primitive = primitives.getJSONObject(primitiveIndex)
          unsupported(integer(primitive, "mode", 4) == 4 && !primitive.has("targets"))
          rejectExtensions(primitive)
          val attributes = primitive.getJSONObject("attributes")
          val allowed = setOf("POSITION", "NORMAL", "JOINTS_0", "WEIGHTS_0", "TEXCOORD_0")
          for (key in attributes.keys()) unsupported(key in allowed)
          val positionAccessor = accessor(integer(attributes, "POSITION"))
          val vertexCount = integer(positionAccessor, "count")
          unsupported(vertexCount in 3..20000)
          val positions = floats(integer(attributes, "POSITION"), "VEC3", vertexCount)
          if (attributes.has("NORMAL")) floats(integer(attributes, "NORMAL"), "VEC3", vertexCount)
          val joints = unsigned(integer(attributes, "JOINTS_0"), "VEC4", vertexCount, false)
          for (joint in joints) invalid(joint in jointNodes.indices)
          val weights = weights(integer(attributes, "WEIGHTS_0"), vertexCount)
          val texCoords = if (attributes.has("TEXCOORD_0")) floats(integer(attributes, "TEXCOORD_0"), "VEC2", vertexCount) else FloatArray(vertexCount * 2)
          val partIndices = if (primitive.has("indices")) {
            val indicesAccessor = accessor(integer(primitive, "indices"))
            val indexCount = integer(indicesAccessor, "count")
            unsupported(indexCount in 3..60000)
            invalid(indexCount % 3 == 0)
            unsigned(integer(primitive, "indices"), "SCALAR", indexCount, true)
          } else {
            invalid(vertexCount % 3 == 0)
            IntArray(vertexCount) { it }
          }
          for (index in partIndices) invalid(index in 0 until vertexCount)
          val material = readMaterial(primitive)
          unsupported((material.texture == null && material.mask == null) || attributes.has("TEXCOORD_0"))
          val vertexOffset = allPositions.size / 3
          val firstIndex = allIndices.size
          allPositions.addAll(positions.toList()); allJoints.addAll(joints.toList())
          allWeights.addAll(weights.toList()); allTexCoords.addAll(texCoords.toList())
          allIndices.addAll(partIndices.map { it + vertexOffset })
          parts.add(RigPart(firstIndex, partIndices.size, material.color, material.texture, material.mask, material.skin, material.tintMode))
          unsupported(allPositions.size / 3 <= 65536 && allIndices.size <= 196608)

        }
      }
      val positions = allPositions.toFloatArray(); val joints = allJoints.toIntArray()
      val weights = allWeights.toFloatArray(); val texCoords = allTexCoords.toFloatArray()
      val indices = allIndices.toIntArray(); val vertexCount = positions.size / 3
      val animationJson = json.getJSONArray("animations")
      unsupported(animationJson.length() in 1..16)
      val clips = Array(animationJson.length()) { clipIndex ->
        readClip(animationJson.getJSONObject(clipIndex), nodes)
      }
      val model = RiggedGlbModel(positions, joints, weights, indices, parts[0].color, texCoords, parts[0].texture, nodes, parents, order, jointNodes, inverseBind, clips, parts.toTypedArray())
      // Bounds come from the actual bind pose, after hierarchy and inverse binds,
      // rather than assuming POSITION.min/max describes glTF's scene Y axis.
      val pose = RiggedPoseEvaluator(model)
      pose.evaluateRest()
      var minX = Double.POSITIVE_INFINITY
      var maxX = Double.NEGATIVE_INFINITY
      var minY = Double.POSITIVE_INFINITY
      var maxY = Double.NEGATIVE_INFINITY
      var minZ = Double.POSITIVE_INFINITY
      var maxZ = Double.NEGATIVE_INFINITY
      for (vertex in 0 until vertexCount) {
        checkCancelled()
        val position = DoubleArray(3)
        for (influence in 0..3) {
          val influenceIndex = vertex * 4 + influence
          val weight = weights[influenceIndex].toDouble()
          val paletteOffset = joints[influenceIndex] * 16
          for (axis in 0..2) {
            position[axis] += weight * (
              pose.palette[paletteOffset + axis] * positions[vertex * 3] +
                pose.palette[paletteOffset + 4 + axis] * positions[vertex * 3 + 1] +
                pose.palette[paletteOffset + 8 + axis] * positions[vertex * 3 + 2] +
                pose.palette[paletteOffset + 12 + axis]
              )
          }
        }
        invalid(position.all { it.isFinite() })
        minX = min(minX, position[0]); maxX = max(maxX, position[0])
        minY = min(minY, position[1]); maxY = max(maxY, position[1])
        minZ = min(minZ, position[2]); maxZ = max(maxZ, position[2])
      }
      invalid(maxY - minY > 1e-9)
      doubleArrayOf((minX + maxX) * 0.5, minY, (minZ + maxZ) * 0.5, maxY - minY).copyInto(model.restBounds)
      return model
    }

    private fun readMaterial(primitive: JSONObject): RigMaterial {
      if (!primitive.has("material")) return RigMaterial(floatArrayOf(1f, 1f, 1f, 1f), null)
      val materials = json.getJSONArray("materials")
      val index = integer(primitive, "material")
      invalid(index in 0 until materials.length())
      val material = materials.getJSONObject(index)
      rejectExtensions(material)
      unsupported(material.optString("alphaMode", "OPAQUE") == "OPAQUE")
      for (key in listOf("normalTexture", "occlusionTexture", "emissiveTexture")) unsupported(!material.has(key))
      if (material.has("emissiveFactor")) unsupported(vector(material.getJSONArray("emissiveFactor"), 3).all { it == 0.0 })
      val pbr = material.optJSONObject("pbrMetallicRoughness") ?: JSONObject()
      unsupported(!pbr.has("metallicRoughnessTexture"))
      val color = if (pbr.has("baseColorFactor")) vector(pbr.getJSONArray("baseColorFactor"), 4) else doubleArrayOf(1.0, 1.0, 1.0, 1.0)
      invalid(color.all { it in 0.0..1.0 })
      val texture = if (pbr.has("baseColorTexture")) readTexture(pbr.getJSONObject("baseColorTexture")) else null
      val extras = material.optJSONObject("extras")
      val mask = if (extras != null && extras.has("moveyTintMaskTexture")) readTexture(JSONObject().put("index", integer(extras, "moveyTintMaskTexture"))) else null
      val skin = extras?.optBoolean("moveySkin", false) ?: false
      val tintMode = RigTintMode.decode(extras?.opt("moveyTintMode"))
      invalid(tintMode != RigTintMode.CUSTOMIZER_HEAD || mask != null)
      return RigMaterial(FloatArray(4) { color[it].toFloat() }, texture, mask, skin, tintMode)
    }

    /** Embedded image decoding is performed only on the bounded CPU loader. */
    private fun readTexture(info: JSONObject): RigTexture {
      unsupported(integer(info, "texCoord", 0) == 0)
      val textures = json.getJSONArray("textures")
      val index = integer(info, "index")
      invalid(index in 0 until textures.length())
      textureCache[index]?.let { return it }
      val texture = textures.getJSONObject(index)
      val images = json.getJSONArray("images")
      val source = integer(texture, "source")
      invalid(source in 0 until images.length())
      val image = images.getJSONObject(source)
      unsupported(!image.has("uri"))
      val mimeType = image.getString("mimeType")
      unsupported(mimeType == "image/png" || mimeType == "image/jpeg")
      val viewIndex = integer(image, "bufferView")
      invalid(viewIndex in 0 until views.length())
      val view = views.getJSONObject(viewIndex)
      unsupported(!view.has("byteStride"))
      invalid(integer(view, "buffer") == 0)
      val offset = integer(view, "byteOffset", 0)
      val length = integer(view, "byteLength")
      invalid(length > 0 && offset.toLong() + length <= binaryLength)
      unsupported(length <= 1024 * 1024)
      val encoded = ByteArray(length)
      binary.duplicate().apply { position(offset); get(encoded) }
      val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
      BitmapFactory.decodeByteArray(encoded, 0, encoded.size, bounds)
      invalid(bounds.outMimeType == mimeType)
      unsupported(bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048 && bounds.outWidth.toLong() * bounds.outHeight <= 4_194_304)
      decodedImagePixels += bounds.outWidth.toLong() * bounds.outHeight
      unsupported(decodedImagePixels <= 16_777_216)
      checkCancelled()
      val rgba = decodeRigTexturePixels(encoded, bounds.outWidth, bounds.outHeight) { checkCancelled() }
      val sampler = if (texture.has("sampler")) {
        val samplers = json.getJSONArray("samplers")
        val samplerIndex = integer(texture, "sampler")
        invalid(samplerIndex in 0 until samplers.length())
        samplers.getJSONObject(samplerIndex)
      } else JSONObject()
      val minFilter = integer(sampler, "minFilter", 9729)
      val magFilter = integer(sampler, "magFilter", 9729)
      val wrapS = integer(sampler, "wrapS", 10497)
      val wrapT = integer(sampler, "wrapT", 10497)
      unsupported(minFilter in setOf(9728, 9729, 9984, 9985, 9986, 9987) && magFilter in setOf(9728, 9729))
      unsupported(wrapS in setOf(33071, 33648, 10497) && wrapT in setOf(33071, 33648, 10497))
      return RigTexture(bounds.outWidth, bounds.outHeight, encoded, rgba, minFilter, magFilter, wrapS, wrapT).also { textureCache[index] = it }
    }

    private fun readNode(value: JSONObject): RigNode {
      rejectExtensions(value)
      unsupported(!value.has("weights") && !value.has("camera"))
      val children = if (value.has("children")) intList(value.getJSONArray("children")) else IntArray(0)
      invalid(children.distinct().size == children.size)
      val matrix = if (value.has("matrix")) vector(value.getJSONArray("matrix"), 16) else null
      if (matrix != null) {
        invalid(!value.has("translation") && !value.has("rotation") && !value.has("scale"))
        invalid(abs(matrix[3]) < 1e-8 && abs(matrix[7]) < 1e-8 && abs(matrix[11]) < 1e-8 && abs(matrix[15] - 1.0) < 1e-8)
      }
      val translation = if (value.has("translation")) vector(value.getJSONArray("translation"), 3) else doubleArrayOf(0.0, 0.0, 0.0)
      val rotation = if (value.has("rotation")) quaternion(vector(value.getJSONArray("rotation"), 4)) else doubleArrayOf(0.0, 0.0, 0.0, 1.0)
      val scale = if (value.has("scale")) vector(value.getJSONArray("scale"), 3) else doubleArrayOf(1.0, 1.0, 1.0)
      return RigNode(matrix, translation, rotation, scale, children)
    }

    private fun readClip(value: JSONObject, nodes: Array<RigNode>): RigClip {
      val samplers = value.getJSONArray("samplers")
      val channels = value.getJSONArray("channels")
      unsupported(samplers.length() in 1..384 && channels.length() in 1..384)
      val targets = HashSet<String>()
      var start = Double.POSITIVE_INFINITY
      var end = Double.NEGATIVE_INFINITY
      val result = Array(channels.length()) { index ->
        checkCancelled()
        val channel = channels.getJSONObject(index)
        val samplerIndex = integer(channel, "sampler")
        invalid(samplerIndex in 0 until samplers.length())
        val sampler = samplers.getJSONObject(samplerIndex)
        val interpolation = sampler.optString("interpolation", "LINEAR")
        unsupported(interpolation == "LINEAR" || interpolation == "STEP")
        val target = channel.getJSONObject("target")
        val node = integer(target, "node")
        invalid(node in nodes.indices && nodes[node].matrix == null)
        val path = target.getString("path")
        unsupported(path == "translation" || path == "rotation" || path == "scale")
        invalid(targets.add("$node:$path"))
        val input = integer(sampler, "input")
        val count = integer(accessor(input), "count")
        unsupported(count in 2..4096)
        val times = floats(input, "SCALAR", count)
        for (key in times.indices) invalid(times[key] >= 0f && (key == 0 || times[key] > times[key - 1]))
        val size = if (path == "rotation") 4 else 3
        val output = floats(integer(sampler, "output"), if (size == 4) "VEC4" else "VEC3", count)
        if (size == 4) {
          for (key in 0 until count) {
            val normalized = quaternion(DoubleArray(4) { output[key * 4 + it].toDouble() })
            for (axis in 0..3) output[key * 4 + axis] = normalized[axis].toFloat()
          }
        }
        start = min(start, times.first().toDouble()); end = max(end, times.last().toDouble())
        RigChannel(node, path, interpolation == "STEP", times, output, size)
      }
      invalid(end > start)
      return RigClip(result, start, end)
    }

    private fun accessor(index: Int): JSONObject {
      invalid(index in 0 until accessors.length())
      val value = accessors.getJSONObject(index)
      unsupported(!value.has("sparse"))
      rejectExtensions(value)
      return value
    }

    private fun access(index: Int, type: String, count: Int, allowed: Set<Int>): Access {
      checkCancelled()
      val accessor = accessor(index)
      invalid(accessor.getString("type") == type && integer(accessor, "count") == count)
      val component = integer(accessor, "componentType")
      unsupported(component in allowed)
      val components = when (type) { "SCALAR" -> 1; "VEC2" -> 2; "VEC3" -> 3; "VEC4" -> 4; "MAT4" -> 16; else -> throw GlbException("GLB_UNSUPPORTED") }
      val width = when (component) { 5121 -> 1; 5123 -> 2; 5125, 5126 -> 4; else -> throw GlbException("GLB_UNSUPPORTED") }
      val viewIndex = integer(accessor, "bufferView")
      invalid(viewIndex in 0 until views.length())
      val view = views.getJSONObject(viewIndex)
      rejectExtensions(view)
      invalid(integer(view, "buffer") == 0)
      val offset = integer(view, "byteOffset", 0).toLong()
      val length = integer(view, "byteLength").toLong()
      val accessorOffset = integer(accessor, "byteOffset", 0).toLong()
      val elementSize = components * width
      val stride = integer(view, "byteStride", elementSize)
      invalid(stride >= elementSize && stride % width == 0)
      if (view.has("byteStride")) invalid(stride in 4..252 && stride % 4 == 0)
      invalid(offset + length <= binaryLength && (offset + accessorOffset) % width == 0L)
      val lastByte = accessorOffset + (count.toLong() - 1) * stride + elementSize
      invalid(count > 0 && lastByte <= length && offset + lastByte <= binaryLength)
      copiedScalars += count.toLong() * components
      unsupported(copiedScalars <= 2_000_000)
      if (accessor.has("normalized")) invalid(accessor.get("normalized") is Boolean)
      return Access((offset + accessorOffset).toInt(), stride, count, components, width, component, accessor.optBoolean("normalized", false))
    }

    private fun floats(index: Int, type: String, count: Int): FloatArray {
      val access = access(index, type, count, setOf(5126))
      invalid(!access.normalized)
      return FloatArray(count * access.components) { scalar ->
        if (scalar % 1024 == 0) checkCancelled()
        binary.getFloat(access.offset + (scalar / access.components) * access.stride + (scalar % access.components) * 4).also { invalid(it.isFinite()) }
      }
    }

    private fun unsigned(index: Int, type: String, count: Int, indexData: Boolean): IntArray {
      val access = access(index, type, count, if (indexData) setOf(5121, 5123, 5125) else setOf(5121, 5123))
      invalid(!access.normalized)
      return IntArray(count * access.components) { scalar ->
        if (scalar % 1024 == 0) checkCancelled()
        unsignedAt(access, scalar)
      }
    }

    private fun weights(index: Int, count: Int): FloatArray {
      val access = access(index, "VEC4", count, setOf(5121, 5123, 5126))
      invalid((access.component == 5126 && !access.normalized) || (access.component != 5126 && access.normalized))
      val values = FloatArray(count * 4) { scalar ->
        if (scalar % 1024 == 0) checkCancelled()
        val value = if (access.component == 5126) {
          binary.getFloat(access.offset + scalar / 4 * access.stride + scalar % 4 * 4)
        } else {
          unsignedAt(access, scalar).toFloat() / if (access.component == 5121) 255f else 65535f
        }
        invalid(value.isFinite() && value in 0f..1f)
        value
      }
      for (vertex in 0 until count) {
        var sum = 0f
        for (axis in 0..3) sum += values[vertex * 4 + axis]
        invalid(sum > 0f && abs(sum - 1f) <= 0.01f)
        for (axis in 0..3) values[vertex * 4 + axis] /= sum
      }
      return values
    }

    private fun unsignedAt(access: Access, scalar: Int): Int {
      val offset = access.offset + scalar / access.components * access.stride + scalar % access.components * access.width
      return when (access.component) {
        5121 -> binary.get(offset).toInt() and 255
        5123 -> binary.getShort(offset).toInt() and 65535
        5125 -> binary.getInt(offset).also { invalid(it >= 0) }
        else -> throw GlbException("GLB_INVALID")
      }
    }

    private fun topologicalOrder(nodes: Array<RigNode>, parents: IntArray): IntArray {
      val marks = IntArray(nodes.size)
      val order = ArrayList<Int>(nodes.size)
      fun visit(index: Int) {
        invalid(marks[index] != 1)
        if (marks[index] == 2) return
        marks[index] = 1
        if (parents[index] >= 0) visit(parents[index])
        marks[index] = 2
        order.add(index)
      }
      for (index in nodes.indices) visit(index)
      return order.toIntArray()
    }

    private fun validateJsonDepth(text: String) {
      var depth = 0
      var string = false
      var escaped = false
      var complete = false
      for (character in text) {
        if (string) {
          if (escaped) escaped = false else if (character == '\\') escaped = true else if (character == '"') string = false
        } else {
          if (complete) invalid(character.isWhitespace())
          when (character) {
          '"' -> string = true
          '{', '[' -> { depth++; unsupported(depth <= 64) }
          '}', ']' -> { depth--; invalid(depth >= 0); if (depth == 0) complete = true }
          }
        }
      }
      invalid(depth == 0 && !string)
    }

    private fun validateExtensionsRecursively(value: Any) {
      when (value) {
        is JSONObject -> {
          rejectExtensions(value)
          for (key in value.keys()) validateExtensionsRecursively(value.get(key))
        }
        is JSONArray -> for (index in 0 until value.length()) validateExtensionsRecursively(value.get(index))
        is Number -> invalid(value.toDouble().isFinite())
      }
    }

    private fun rejectExtensions(value: JSONObject) {
      for (key in listOf("extensions", "extensionsUsed", "extensionsRequired")) {
        if (value.has(key)) {
          val extensions = value.get(key)
          unsupported((extensions is JSONObject && extensions.length() == 0) || (extensions is JSONArray && extensions.length() == 0))
        }
      }
    }

    private fun integer(value: JSONObject, key: String, default: Int? = null): Int {
      if (!value.has(key)) return default ?: throw GlbException("GLB_INVALID")
      return numberToInt(value.get(key))
    }

    private fun numberToInt(value: Any): Int {
      invalid(value is Number)
      val number = (value as Number).toDouble()
      invalid(number.isFinite() && number >= 0 && number <= Int.MAX_VALUE && number % 1.0 == 0.0)
      return number.toInt()
    }

    private fun intList(value: JSONArray): IntArray = IntArray(value.length()) { numberToInt(value.get(it)) }

    private fun vector(value: JSONArray, count: Int): DoubleArray {
      invalid(value.length() == count)
      return DoubleArray(count) {
        val item = value.get(it)
        invalid(item is Number)
        (item as Number).toDouble().also { number -> invalid(number.isFinite()) }
      }
    }

    private fun quaternion(value: DoubleArray): DoubleArray {
      val length = sqrt(value.sumOf { it * it })
      invalid(length.isFinite() && length > 1e-9 && abs(length - 1.0) < 0.01)
      for (index in value.indices) value[index] /= length
      return value
    }

    private fun invalid(condition: Boolean) { if (!condition) throw GlbException("GLB_INVALID") }
    private fun unsupported(condition: Boolean) { if (!condition) throw GlbException("GLB_UNSUPPORTED") }
    private fun checkCancelled() { if (Thread.currentThread().isInterrupted) throw InterruptedException() }
    private data class Access(val offset: Int, val stride: Int, val count: Int, val components: Int, val width: Int, val component: Int, val normalized: Boolean)
  }
}

internal class RiggedGlbModel(
  val positions: FloatArray,
  val joints: IntArray,
  val weights: FloatArray,
  val indices: IntArray,
  val color: FloatArray,
  val texCoords: FloatArray,
  val texture: RigTexture?,
  val nodes: Array<RigNode>,
  val parents: IntArray,
  val order: IntArray,
  val jointNodes: IntArray,
  val inverseBind: FloatArray,
  val clips: Array<RigClip>,
  val parts: Array<RigPart> = arrayOf(RigPart(0, indices.size, color, texture, null, false)),
) {
  // Assigned once by the loader before publication to the scene/render threads.
  val restBounds = DoubleArray(4)
  val vertexCount get() = positions.size / 3
  val usesCustomizer get() = parts.any { it.tintMode != RigTintMode.LEGACY }
}

internal enum class RigTintMode(val shaderValue: Float) {
  LEGACY(0f), CUSTOMIZER_HEAD(1f), CUSTOMIZER_SKIN(2f), CUSTOMIZER_LIPS(3f);
  companion object {
    fun decode(value: Any?): RigTintMode = when (value) {
      null -> LEGACY
      "CUSTOMIZER_V5_HEAD" -> CUSTOMIZER_HEAD
      "CUSTOMIZER_V5_SKIN" -> CUSTOMIZER_SKIN
      "CUSTOMIZER_V5_LIPS" -> CUSTOMIZER_LIPS
      else -> throw GlbException("GLB_UNSUPPORTED")
    }
  }
}

/** Compressed pixels survive style/context recreation; decoded upload pixels do not. */
internal class RigTexture(
  val width: Int, val height: Int, private val encoded: ByteArray,
  initialPixels: ByteArray, val minFilter: Int, val magFilter: Int, val wrapS: Int, val wrapT: Int,
) {
  private var uploadPixels: ByteArray? = initialPixels
  @Synchronized fun pixels(): ByteArray = uploadPixels ?: decodeRigTexturePixels(encoded, width, height) {}.also { uploadPixels = it }
  @Synchronized fun releasePixels() { uploadPixels = null }
}

private fun decodeRigTexturePixels(encoded: ByteArray, width: Int, height: Int, checkCancelled: () -> Unit): ByteArray {
  val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888; inScaled = false }
  val bitmap = BitmapFactory.decodeByteArray(encoded, 0, encoded.size, options) ?: throw GlbException("GLB_INVALID")
  try {
    if (bitmap.width != width || bitmap.height != height) throw GlbException("GLB_INVALID")
    // Replacement retains the current actor; one row avoids a second 16 MiB
    // full-size ARGB scratch array when a 2K atlas is converted for upload.
    val rowPixels = IntArray(width)
    val rgba = ByteArray(width * height * 4)
    for (row in 0 until height) {
      checkCancelled()
      bitmap.getPixels(rowPixels, 0, width, 0, row, width, 1)
      for (column in rowPixels.indices) {
        val value = rowPixels[column]
        val offset = (row * width + column) * 4
        rgba[offset] = (value ushr 16).toByte()
        rgba[offset + 1] = (value ushr 8).toByte()
        rgba[offset + 2] = value.toByte()
        rgba[offset + 3] = (value ushr 24).toByte()
      }
    }
    return rgba
  } finally { bitmap.recycle() }
}
internal class RigPart(val firstIndex: Int, val indexCount: Int, val color: FloatArray, val texture: RigTexture?, val mask: RigTexture?, val skin: Boolean, val tintMode: RigTintMode = RigTintMode.LEGACY)
private class RigMaterial(val color: FloatArray, val texture: RigTexture?, val mask: RigTexture? = null, val skin: Boolean = false, val tintMode: RigTintMode = RigTintMode.LEGACY)

internal class RigNode(val matrix: DoubleArray?, val translation: DoubleArray, val rotation: DoubleArray, val scale: DoubleArray, val children: IntArray)
internal class RigClip(val channels: Array<RigChannel>, val start: Double, val end: Double) { val duration get() = end }
internal class RigChannel(val node: Int, val path: String, val step: Boolean, val times: FloatArray, val values: FloatArray, val size: Int)

/** Mutable per-instance pose; only the native render thread evaluates it. */
internal class RiggedPoseEvaluator(private val model: RiggedGlbModel) {
  val palette = FloatArray(model.jointNodes.size * 16)
  private val local = DoubleArray(model.nodes.size * 16)
  private val global = DoubleArray(model.nodes.size * 16)
  private val translations = DoubleArray(model.nodes.size * 3)
  private val rotations = DoubleArray(model.nodes.size * 4)
  private val scales = DoubleArray(model.nodes.size * 3)
  private val sample = DoubleArray(4)

  fun evaluateRest() { reset(); compose() }

  fun evaluate(clip: RigClip, seconds: Double): Boolean {
    reset()
    // Input key times remain relative to timeline zero. A channel whose first
    // key is later than zero clamps to that first value until its key time.
    val time = seconds % clip.duration
    for (channel in clip.channels) {
      val times = channel.times
      var low = 0
      var high = times.lastIndex
      while (low < high) {
        val middle = (low + high + 1) / 2
        if (times[middle] <= time) low = middle else high = middle - 1
      }
      val next = min(low + 1, times.lastIndex)
      val fraction = if (channel.step || next == low) 0.0 else ((time - times[low]) / (times[next] - times[low])).coerceIn(0.0, 1.0)
      if (channel.path == "rotation") {
        slerp(channel.values, low * 4, next * 4, fraction, sample)
      } else for (axis in 0 until channel.size) {
        val a = channel.values[low * channel.size + axis].toDouble()
        sample[axis] = a + (channel.values[next * channel.size + axis] - a) * fraction
      }
      val destination = when (channel.path) { "translation" -> translations; "rotation" -> rotations; else -> scales }
      for (axis in 0 until channel.size) destination[channel.node * channel.size + axis] = sample[axis]
    }
    return compose()
  }

  private fun reset() {
    for (index in model.nodes.indices) {
      val node = model.nodes[index]
      node.translation.copyInto(translations, index * 3)
      node.rotation.copyInto(rotations, index * 4)
      node.scale.copyInto(scales, index * 3)
      node.matrix?.copyInto(local, index * 16)
    }
  }

  private fun compose(): Boolean {
    for (index in model.order) {
      val offset = index * 16
      if (model.nodes[index].matrix == null) RigMatrix.compose(local, offset, translations, index * 3, rotations, index * 4, scales, index * 3)
      val parent = model.parents[index]
      if (parent < 0) local.copyInto(global, offset, offset, offset + 16) else RigMatrix.multiply(global, parent * 16, local, offset, global, offset)
    }
    var changed = false
    for (joint in model.jointNodes.indices) {
      val globalOffset = model.jointNodes[joint] * 16
      val bindOffset = joint * 16
      for (column in 0..3) for (row in 0..3) {
        var value = 0.0
        for (axis in 0..3) value += global[globalOffset + axis * 4 + row] * model.inverseBind[bindOffset + column * 4 + axis]
        val index = bindOffset + column * 4 + row
        val next = value.toFloat()
        if (!next.isFinite()) throw GlbException("POSE_INVALID")
        if (palette[index] != next) changed = true
        palette[index] = next
      }
    }
    return changed
  }

  private fun slerp(values: FloatArray, first: Int, second: Int, fraction: Double, result: DoubleArray) {
    var dot = 0.0
    for (axis in 0..3) dot += values[first + axis] * values[second + axis]
    val sign = if (dot < 0) -1.0 else 1.0
    dot = abs(dot).coerceIn(0.0, 1.0)
    val theta = acos(dot)
    val sine = sin(theta)
    val a = if (dot > 0.9995) 1 - fraction else sin((1 - fraction) * theta) / sine
    val b = if (dot > 0.9995) fraction else sin(fraction * theta) / sine
    var length = 0.0
    for (axis in 0..3) {
      result[axis] = a * values[first + axis] + b * sign * values[second + axis]
      length += result[axis] * result[axis]
    }
    length = sqrt(length)
    for (axis in 0..3) result[axis] /= length
  }
}

internal object RigMatrix {
  fun multiply(a: DoubleArray, ao: Int, b: DoubleArray, bo: Int, out: DoubleArray, offset: Int) {
    for (column in 0..3) for (row in 0..3) {
      var value = 0.0
      for (axis in 0..3) value += a[ao + axis * 4 + row] * b[bo + column * 4 + axis]
      out[offset + column * 4 + row] = value
    }
  }

  fun compose(out: DoubleArray, offset: Int, t: DoubleArray, to: Int, r: DoubleArray, ro: Int, s: DoubleArray, so: Int) {
    val x = r[ro]; val y = r[ro + 1]; val z = r[ro + 2]; val w = r[ro + 3]
    out[offset] = (1 - 2 * (y * y + z * z)) * s[so]
    out[offset + 1] = (2 * (x * y + z * w)) * s[so]
    out[offset + 2] = (2 * (x * z - y * w)) * s[so]
    out[offset + 3] = 0.0
    out[offset + 4] = (2 * (x * y - z * w)) * s[so + 1]
    out[offset + 5] = (1 - 2 * (x * x + z * z)) * s[so + 1]
    out[offset + 6] = (2 * (y * z + x * w)) * s[so + 1]
    out[offset + 7] = 0.0
    out[offset + 8] = (2 * (x * z + y * w)) * s[so + 2]
    out[offset + 9] = (2 * (y * z - x * w)) * s[so + 2]
    out[offset + 10] = (1 - 2 * (x * x + y * y)) * s[so + 2]
    out[offset + 11] = 0.0
    out[offset + 12] = t[to]; out[offset + 13] = t[to + 1]; out[offset + 14] = t[to + 2]; out[offset + 15] = 1.0
  }
}
