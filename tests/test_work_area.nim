# SPDX-License-Identifier: 0BSD

import std/unittest
import ../work_area

suite "layer-shell work areas":
  test "exclusive zones are global-coordinate hints clipped to the output":
    let bounds = Box(x: 100, y: 200, width: 1920, height: 1080)
    let reserved = Box(x: 100, y: 232, width: 1920, height: 1048)
    check usableArea(bounds, reserved) == reserved
    check usableArea(bounds, Box(x: 0, y: 0, width: 2000, height: 1000)) ==
      Box(x: 100, y: 200, width: 1900, height: 800)

  test "invalid and unrelated hints fall back to the full output":
    let bounds = Box(width: 1280, height: 720)
    for hint in [Box(), Box(width: -1, height: 10),
        Box(x: 5000, y: 5000, width: 100, height: 100)]:
      check usableArea(bounds, hint) == bounds

  test "window titlebars and borders stay below a top panel":
    let area = Box(y: 30, width: 1280, height: 690)
    check fitPosition(area, 0, 0, 640, 480, 2, 24) == (2'i32, 56'i32)
    check fitPosition(area, 0, 0, 640, 480, 2, 0) == (2'i32, 32'i32)
    check fitPosition(area, 9999, 9999, 640, 480, 2, 24) == (638'i32, 238'i32)

  test "oversized floating windows keep their titlebar accessible":
    let area = Box(y: 32, width: 800, height: 568)
    check fitPosition(area, 100, 100, 2000, 1000, 2, 24) == (2'i32, 58'i32)

  test "secondary outputs use their own global work areas":
    let area = Box(x: -1280, y: 752, width: 1280, height: 688)
    check fitPosition(area, area.x, area.y, 640, 480, 2, 24) == (-1278'i32, 778'i32)
    check area.contains(-1270, 800)
    check not area.contains(0, 800)

  test "window/output overlap uses 64-bit area calculations":
    let large = Box(width: high(int32), height: high(int32))
    check large.overlap(large) == high(int32).int64 * high(int32).int64
    check Box(width: 100, height: 100).overlap(Box(x: 50, y: 50, width: 100, height: 100)) == 2500

  test "tiny areas and extreme coordinates don't overflow":
    check fitPosition(Box(width: 1, height: 1), 100, 100, 640, 480, 2, 24) == (0'i32, 0'i32)
    let area = Box(x: high(int32) - 10, y: low(int32), width: 10, height: 10)
    check area.valid
    let position = fitPosition(area, 0, 0, 640, 480, 2, 24)
    check area.contains(position.x, position.y)
    check not Box(x: high(int32) - 10, width: 20, height: 20).valid
    check fitPosition(Box(), 10, 20, 640, 480, 2, 24) == (10'i32, 20'i32)
