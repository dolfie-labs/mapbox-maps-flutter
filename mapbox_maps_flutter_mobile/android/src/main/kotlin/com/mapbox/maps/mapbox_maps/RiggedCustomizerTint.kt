package com.mapbox.maps.mapbox_maps

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Linear-sRGB operations from the saved V5 Customizer material graph. */
internal object RiggedCustomizerTint {
  val skinReference = floatArrayOf(0.88792324f, 0.38132605f, 0.1559265f)
  val eyeReference = floatArrayOf(0.18f, 0.055f, 0.022f)

  fun lipValue(skin: FloatArray): Float {
    val weights = floatArrayOf(0.2126f, 0.7152f, 0.0722f)
    val value = skin.indices.sumOf { (skin[it] * weights[it]).toDouble() }
    val reference = skinReference.indices.sumOf { (skinReference[it] * weights[it]).toDouble() }
    return sqrt(value / reference).coerceIn(0.2, 1.2).toFloat()
  }

  fun hsv(rgb: FloatArray): FloatArray {
    val maximum = max(rgb[0], max(rgb[1], rgb[2]))
    val minimum = min(rgb[0], min(rgb[1], rgb[2]))
    val difference = maximum - minimum
    if (difference <= 0f) return floatArrayOf(0f, 0f, maximum)
    val hue = when (maximum) {
      rgb[0] -> (rgb[1] - rgb[2]) / difference + if (rgb[1] < rgb[2]) 6f else 0f
      rgb[1] -> (rgb[2] - rgb[0]) / difference + 2f
      else -> (rgb[0] - rgb[1]) / difference + 4f
    }
    return floatArrayOf(hue / 6f, if (maximum > 0f) difference / maximum else 0f, maximum)
  }

  fun rgb(hsv: FloatArray): FloatArray {
    val hue = (hsv[0] - floor(hsv[0])) * 6f
    val sector = floor(hue).toInt()
    val fraction = hue - floor(hue)
    val p = hsv[2] * (1f - hsv[1])
    val q = hsv[2] * (1f - hsv[1] * fraction)
    val t = hsv[2] * (1f - hsv[1] * (1f - fraction))
    return when (sector) {
      0 -> floatArrayOf(hsv[2], t, p)
      1 -> floatArrayOf(q, hsv[2], p)
      2 -> floatArrayOf(p, hsv[2], t)
      3 -> floatArrayOf(p, q, hsv[2])
      4 -> floatArrayOf(t, p, hsv[2])
      else -> floatArrayOf(hsv[2], p, q)
    }
  }

  fun shade(base: FloatArray, mask: FloatArray, skin: FloatArray, eye: FloatArray): FloatArray {
    val color = FloatArray(3) { base[it] * (1f + mask[0] * (skin[it] / skinReference[it] - 1f)) }
    val adjusted = hsv(color)
    val target = hsv(eye)
    val reference = hsv(eyeReference)
    adjusted[0] += target[0] - reference[0]
    adjusted[1] = (adjusted[1] * target[1] / reference[1]).coerceIn(0f, 1f)
    adjusted[2] *= (target[2] / reference[2]).coerceIn(0.25f, 1.4f)
    val iris = rgb(adjusted)
    val lip = 1f + mask[2] * (lipValue(skin) - 1f)
    return FloatArray(3) { max(0f, (color[it] + (iris[it] - color[it]) * mask[1]) * lip) }
  }
}
