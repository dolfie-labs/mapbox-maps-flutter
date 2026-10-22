package com.mapbox.maps.mapbox_maps

import kotlin.math.abs
import kotlin.math.max

internal data class RiggedPlacement(val latitude: Double, val longitude: Double, val headingDegrees: Double)

private const val POSITION_DURATION_NANOS = 500_000_000L

/** Separate clocks keep GPS placement updates from restarting an ongoing turn. */
internal data class RiggedPlacementTransition(
  val from: RiggedPlacement,
  val to: RiggedPlacement,
  val startedNanos: Long,
  private val headingFrom: Double = from.headingDegrees,
  private val headingStartedNanos: Long = startedNanos,
  private val headingDurationNanos: Long = turnDuration(from.headingDegrees, to.headingDegrees),
) {
  fun retarget(target: RiggedPlacement, now: Long): RiggedPlacementTransition {
    val current = sample(now)
    val changedHeading = shortestArc(target.headingDegrees - to.headingDegrees) != 0.0
    return RiggedPlacementTransition(
      current, target, now,
      if (changedHeading) current.headingDegrees else headingFrom,
      if (changedHeading) now else headingStartedNanos,
      if (changedHeading) turnDuration(current.headingDegrees, target.headingDegrees) else headingDurationNanos,
    )
  }

  fun isMoving(now: Long): Boolean = startedNanos != 0L &&
    (now - startedNanos < POSITION_DURATION_NANOS || now - headingStartedNanos < headingDurationNanos)

  fun sample(now: Long): RiggedPlacement {
    if (startedNanos == 0L) return to
    val fraction = ((now - startedNanos).toDouble() / POSITION_DURATION_NANOS).coerceIn(0.0, 1.0)
    val turn = ((now - headingStartedNanos).toDouble() / headingDurationNanos).coerceIn(0.0, 1.0)
    val eased = turn * turn * (3.0 - 2.0 * turn)
    val longitude = from.longitude + shortestArc(to.longitude - from.longitude) * fraction
    return RiggedPlacement(
      from.latitude + (to.latitude - from.latitude) * fraction,
      ((longitude + 540.0) % 360.0) - 180.0,
      ((headingFrom + shortestArc(to.headingDegrees - headingFrom) * eased) % 360.0 + 360.0) % 360.0,
    )
  }
}

private fun shortestArc(value: Double): Double = ((value % 360.0 + 540.0) % 360.0) - 180.0
private fun turnDuration(from: Double, to: Double): Long =
  max(POSITION_DURATION_NANOS, (abs(shortestArc(to - from)) / 120.0 * 1_000_000_000).toLong())
