package com.mapbox.maps.mapbox_maps

import java.util.concurrent.atomic.AtomicReference

/** Monotonic visibility clock, independent of the paused skeletal clock. */
internal class RiggedOpacity(initial: Double = 1.0) {
  private val transition = AtomicReference(RiggedOpacityTransition(initial, initial, 0L, 0L))
  private val settled = AtomicReference(transition.get())

  init { require(initial.isFinite() && initial in 0.0..1.0) }

  fun update(target: Double, milliseconds: Long, now: Long) {
    require(target.isFinite() && target in 0.0..1.0 && milliseconds in 0L..1000L)
    val previous = transition.get()
    // GPS/clip commands may repeat the requested opacity while a fade runs.
    // Keeping this transition also keeps its original deadline.
    if (target == previous.to) return
    val current = previous.sample(now)
    val next = RiggedOpacityTransition(current, target, now, milliseconds * 1_000_000L)
    transition.set(next)
    if (milliseconds == 0L || current == target) settled.set(next)
  }

  fun snapshot(now: Long): RiggedOpacitySnapshot {
    val current = transition.get()
    return RiggedOpacitySnapshot(current.sample(now), current.to, !current.finished(now))
  }

  /** The render endpoint must be submitted once before a paused fade stops. */
  fun needsFrame(): Boolean = settled.get() !== transition.get()

  fun sample(now: Long): Double {
    val current = transition.get()
    if (current.finished(now)) settled.set(current)
    return current.sample(now)
  }
}

internal data class RiggedOpacitySnapshot(val value: Double, val target: Double, val isAnimating: Boolean) {
  val hidden: Boolean get() = value == 0.0 && target == 0.0
}

private data class RiggedOpacityTransition(val from: Double, val to: Double, val startedNanos: Long, val durationNanos: Long) {
  fun finished(now: Long): Boolean = durationNanos == 0L || from == to || now - startedNanos >= durationNanos
  fun sample(now: Long): Double {
    if (finished(now)) return to
    val fraction = ((now - startedNanos).toDouble() / durationNanos).coerceIn(0.0, 1.0)
    return from + (to - from) * fraction
  }
}
