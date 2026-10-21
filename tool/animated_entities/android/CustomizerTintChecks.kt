package com.mapbox.maps.mapbox_maps

import java.io.File
import kotlin.math.abs
import org.json.JSONObject

fun main(arguments: Array<String>) {
  val source = arguments.firstOrNull() ?: "tool/animated_entities/fixtures/customizer-tint-cases.json"
  val cases = JSONObject(File(source).readText()).getJSONArray("cases")
  var maximum = 0f
  for (index in 0 until cases.length()) {
    val row = cases.getJSONObject(index)
    fun vector(key: String) = row.getJSONArray(key).let { values -> FloatArray(3) { values.getDouble(it).toFloat() } }
    val actual = RiggedCustomizerTint.shade(vector("baseLinear"), vector("mask"), vector("skinLinear"), vector("eyeLinear"))
    val expected = vector("expectedLinear")
    for (channel in 0..2) {
      val error = abs(actual[channel] - expected[channel])
      maximum = maxOf(maximum, error)
      check(error < 0.00001f) { "Customizer graph mismatch ${row.getString("name")}: ${actual.toList()} != ${expected.toList()}" }
    }
  }
  println("PASS ${cases.length()} saved Blender/Cycles tint graph probes; maximum linear error $maximum")
}
