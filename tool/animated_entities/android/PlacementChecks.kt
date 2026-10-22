package com.mapbox.maps.mapbox_maps

import kotlin.math.abs

fun main() {
  fun at(seconds: Double) = (seconds * 1_000_000_000).toLong()
  fun close(actual: Double, expected: Double) = check(abs(actual - expected) < 1e-7) { "$actual != $expected" }
  val initial = RiggedPlacement(10.0, 20.0, 0.0)
  var turn = RiggedPlacementTransition(initial, initial, 0).retarget(RiggedPlacement(12.0, 22.0, 180.0), at(1.0))
  close(turn.sample(at(1.0)).headingDegrees, 0.0)
  check(turn.sample(at(1.1)).headingDegrees > 357.0)
  close(turn.sample(at(1.5)).latitude, 12.0)
  check(turn.isMoving(at(1.5)))
  close(turn.sample(at(1.75)).headingDegrees, 270.0)
  turn = turn.retarget(RiggedPlacement(13.0, 23.0, 180.0), at(1.5))
  close(turn.sample(at(1.75)).headingDegrees, 270.0)
  close(turn.sample(at(2.5)).headingDegrees, 180.0)
  check(!turn.isMoving(at(2.5)))
  turn = turn.retarget(RiggedPlacement(14.0, 24.0, 90.0), at(3.0))
  val before = turn.sample(at(3.2)).headingDegrees
  turn = turn.retarget(RiggedPlacement(15.0, 25.0, 0.0), at(3.2))
  close(turn.sample(at(3.2)).headingDegrees, before)
  val wrapped = RiggedPlacement(10.0, 179.0, 350.0)
  val short = RiggedPlacementTransition(wrapped, wrapped, 0).retarget(RiggedPlacement(12.0, -179.0, 10.0), at(1.0))
  close(short.sample(at(1.25)).headingDegrees, 0.0)
  close(short.sample(at(1.25)).longitude, -180.0)
  close(short.sample(at(1.5)).headingDegrees, 10.0)
  println("PASS eased 180-degree turns, independent GPS/heading clocks, short arcs and retarget continuity")
}
