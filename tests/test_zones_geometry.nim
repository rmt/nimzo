# SPDX-License-Identifier: 0BSD

# Test percentage-to-pixel rounding, zone selection by overlap, and
# fixed-size window placement.

import std/unittest
import ../zones_geometry

suite "zones geometry":
  let area = ZoneBox(x: -100, y: 20, width: 1001, height: 601)

  test "percentage edges share rounded coordinates on odd outputs":
    let left = ZoneDef(name: "left", x: 0, y: 0, width: 50, height: 100)
    let right = ZoneDef(name: "right", x: 50, y: 0, width: 50, height: 100)
    let leftBox = zoneBox(left, area)
    let rightBox = zoneBox(right, area)
    check leftBox.x == -100
    check leftBox.width == 501
    check rightBox.x == 401
    check rightBox.width == 500
    check leftBox.x + leftBox.width == rightBox.x

  test "best zone prefers greatest overlap":
    let zones = [
      ZoneDef(name: "a", x: 0, y: 0, width: 50, height: 100),
      ZoneDef(name: "b", x: 50, y: 0, width: 50, height: 100)]
    check bestZone(zones, area, ZoneBox(x: -100, y: 20, width: 200, height: 200)) == 0
    check bestZone(zones, area, ZoneBox(x: 400, y: 20, width: 200, height: 200)) == 1

  test "manual zone requires overlap and keeps the current zone on a tie":
    let zones = [
      ZoneDef(name: "left", x: 0, y: 0, width: 50, height: 100),
      ZoneDef(name: "right", x: 50, y: 0, width: 50, height: 100)]
    let tied = ZoneBox(x: 301, y: 20, width: 200, height: 200)
    check bestOverlappingZone(zones, area, tied, 1) == 1
    check bestOverlappingZone(zones, area, tied, -1) == 0
    let mostlyRight = ZoneBox(x: 302, y: 20, width: 200, height: 200)
    check bestOverlappingZone(zones, area, mostlyRight, 0) == 1
    let outside = ZoneBox(x: -300, y: 20, width: 200, height: 200)
    check bestOverlappingZone(zones, area, outside, 1) == -1

  test "fixed placement aligns one-edge zones and centers full-span axes":
    let north = ZoneDef(name: "north", x: 0, y: 0, width: 100, height: 50)
    let west = ZoneDef(name: "west", x: 0, y: 0, width: 50, height: 100)
    let northPlacement = zonePlacement(north, area, ZoneBox(width: 200, height: 100), true)
    let westPlacement = zonePlacement(west, area, ZoneBox(width: 200, height: 100), true)
    check northPlacement == ZoneBox(x: 300, y: 20, width: 200, height: 100)
    check westPlacement == ZoneBox(x: -100, y: 270, width: 200, height: 100)

  test "oversized fixed windows retain dimensions at area origin":
    let zone = ZoneDef(name: "left", x: 0, y: 0, width: 50, height: 100)
    check zonePlacement(zone, area, ZoneBox(width: 2000, height: 2000), true) ==
      ZoneBox(x: -100, y: 20, width: 2000, height: 2000)
