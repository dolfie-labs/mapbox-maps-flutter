package com.mapbox.maps.mapbox_maps

/** JVM checks for the same monotonic visibility state used by the GLES host. */
fun main() {
  val start = 1_000_000_000L
  fun equal(actual: Double, expected: Double) = check(kotlin.math.abs(actual - expected) < 0.000001) { "$actual != $expected" }
  fun invalid(block: () -> Unit) {
    var rejected = false
    try { block() } catch (_: IllegalArgumentException) { rejected = true }
    check(rejected)
  }

  val original = RiggedOpacity()
  equal(original.sample(start), 1.0)
  check(!original.needsFrame() && !original.snapshot(start).isAnimating)

  val opacity = RiggedOpacity(0.0)
  check(opacity.snapshot(start).hidden && !opacity.needsFrame())
  opacity.update(1.0, 220L, start)
  equal(opacity.sample(start), 0.0)
  check(opacity.needsFrame() && opacity.snapshot(start).isAnimating)
  equal(opacity.sample(start + 110_000_000L), 0.5)

  // A repeated target (for example a GPS update) must not restart a fade.
  opacity.update(1.0, 220L, start + 110_000_000L)
  equal(opacity.sample(start + 165_000_000L), 0.75)
  check(!opacity.snapshot(start + 220_000_000L).isAnimating)
  check(opacity.needsFrame()) // The final render endpoint has not been sampled.
  equal(opacity.sample(start + 220_000_000L), 1.0)
  check(!opacity.needsFrame())

  // Visibility is independent of skeletal animation time or its pause flag.
  opacity.update(0.0, 220L, start + 300_000_000L)
  equal(opacity.sample(start + 410_000_000L), 0.5)
  opacity.update(1.0, 100L, start + 410_000_000L)
  equal(opacity.sample(start + 460_000_000L), 0.75)
  equal(opacity.sample(start + 510_000_000L), 1.0)
  check(!opacity.needsFrame())

  opacity.update(0.0, 0L, start + 600_000_000L)
  check(opacity.snapshot(start + 600_000_000L).hidden && !opacity.needsFrame())
  equal(opacity.sample(start + 600_000_000L), 0.0)
  opacity.update(1.0, 1000L, start + 700_000_000L)
  equal(opacity.sample(start + 1_700_000_000L), 1.0)
  check(!opacity.needsFrame())

  invalid { RiggedOpacity(Double.NaN) }
  invalid { RiggedOpacity(-0.1) }
  invalid { RiggedOpacity(1.1) }
  invalid { opacity.update(Double.POSITIVE_INFINITY, 0L, start) }
  invalid { opacity.update(-0.1, 0L, start) }
  invalid { opacity.update(1.1, 0L, start) }
  invalid { opacity.update(0.0, -1L, start) }
  invalid { opacity.update(0.0, 1001L, start) }
  println("PASS: default/hidden state, monotonic fades, unchanged target, endpoint frame, reversal, immediate hide and bounds")
}
