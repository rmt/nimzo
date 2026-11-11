# SPDX-License-Identifier: 0BSD

import std/unittest
import ../[work_area, zones]

suite "zones geometry":
  let area = Box(x: -100, y: 20, width: 1001, height: 601)

  test "percentage edges use global usable coordinates":
    let zone = Zone(name: "left", x: 0, y: 0, width: 50, height: 100)
    check zone.zoneBox(area) == Box(x: -100, y: 20, width: 501, height: 601)

  test "best zone uses overlap, size, and declaration order":
    let zones = [
      Zone(name: "a", x: 0, y: 0, width: 50, height: 100),
      Zone(name: "b", x: 50, y: 0, width: 50, height: 100)]
    check bestZone(zones, area, Box(x: -100, y: 20, width: 200, height: 200)) == 0
    check bestZone(zones, area, Box(x: 400, y: 20, width: 200, height: 200)) == 1

  test "initial placement avoids occupied zones":
    let zones = [Zone(name: "a", x: 0, y: 0, width: 50, height: 100),
      Zone(name: "b", x: 50, y: 0, width: 50, height: 100)]
    check initialZone(zones, area, Box(x: -100, y: 20, width: 200, height: 200),
      [true, false]) == 1

  test "initial placement chooses closest-sized free zone rather than overlap":
    let zones = [Zone(name: "small", x: 0, y: 0, width: 25, height: 100),
      Zone(name: "large", x: 25, y: 0, width: 75, height: 100)]
    check initialZone(zones, area, Box(x: -100, y: 20, width: 700, height: 500),
      [true, false]) == 1

  test "normal placement expands to the complete decorated zone":
    let zone = Zone(name: "left", x: 0, y: 0, width: 50, height: 100)
    let placed = zonePlacement(zone, area, Box(width: 10, height: 10), false, 2, 24)
    check placed == Box(x: -98, y: 46, width: 497, height: 573)

  test "fixed placement preserves dimensions":
    let zone = Zone(name: "left", x: 0, y: 0, width: 50, height: 100)
    check zonePlacement(zone, area, Box(width: 2000, height: 2000), true, 2, 24).width == 2000
  test "fixed full-span axes center while one-edge axes align":
    let north = Zone(name: "north", x: 0, y: 0, width: 100, height: 50)
    let west = Zone(name: "west", x: 0, y: 0, width: 50, height: 100)
    let horizontal = zonePlacement(north, area, Box(width: 200, height: 100), true, 2, 24)
    let vertical = zonePlacement(west, area, Box(width: 200, height: 100), true, 2, 24)
    check horizontal.x == 300
    check vertical.y == 282
