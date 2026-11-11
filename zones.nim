# SPDX-License-Identifier: 0BSD

import std/math
import work_area

type
  LayoutMethod* = enum
    layoutZones

  Zone* = object
    name*: string
    x*, y*, width*, height*: float64

proc percentCoordinate(value: float64; origin, extent: int32): int64 =
  ## Percentages are converted to global integer coordinates with stable
  ## half-up rounding.  Calculating edges (rather than widths) avoids gaps
  ## between adjacent zones on odd-sized outputs.
  origin.int64 + floor(value * extent.float64 / 100.0 + 0.5).int64

proc zoneBox*(zone: Zone; area: Box): Box =
  if zone.x.classify in {fcNan, fcInf, fcNegInf} or
      zone.y.classify in {fcNan, fcInf, fcNegInf} or
      zone.width.classify in {fcNan, fcInf, fcNegInf} or
      zone.height.classify in {fcNan, fcInf, fcNegInf} or
      zone.x < 0 or zone.y < 0 or zone.width <= 0 or zone.height <= 0 or
      zone.x + zone.width > 100 or zone.y + zone.height > 100:
    return
  if not area.valid: return
  let left = percentCoordinate(zone.x, area.x, area.width)
  let top = percentCoordinate(zone.y, area.y, area.height)
  let right = percentCoordinate(zone.x + zone.width, area.x, area.width)
  let bottom = percentCoordinate(zone.y + zone.height, area.y, area.height)
  if right <= left or bottom <= top: return
  if left < low(int32).int64 or top < low(int32).int64 or
      right > high(int32).int64 or bottom > high(int32).int64: return
  Box(x: left.int32, y: top.int32, width: (right - left).int32,
    height: (bottom - top).int32)

proc sizeDifference(target, window: Box): float64 =
  let widthScale = max(target.width.float64, max(window.width.float64, 1.0))
  let heightScale = max(target.height.float64, max(window.height.float64, 1.0))
  abs(target.width.float64 - window.width.float64) / widthScale +
    abs(target.height.float64 - window.height.float64) / heightScale

proc centerDistance(a, b: Box): float64 =
  let ax = a.x.float64 + a.width.float64 / 2.0
  let ay = a.y.float64 + a.height.float64 / 2.0
  let bx = b.x.float64 + b.width.float64 / 2.0
  let by = b.y.float64 + b.height.float64 / 2.0
  let dx = ax - bx
  let dy = ay - by
  dx * dx + dy * dy

proc bestZone*(zones: openArray[Zone]; area, window: Box): int =
  ## Select the zone containing the greatest part of the current window.  A
  ## zero-overlap window is assigned to the nearest zone center.
  result = -1
  if not area.valid or not window.valid: return
  var bestOverlap: int64 = -1
  var bestSize = Inf
  var bestDistance = Inf
  var foundOverlap = false
  for i, zone in zones:
    let target = zone.zoneBox(area)
    if not target.valid: continue
    let common = target.overlap(window)
    if common > 0 and foundOverlap and common < bestOverlap: continue
    if common > 0:
      let size = sizeDifference(target, window)
      if not foundOverlap or common > bestOverlap or
          (common == bestOverlap and size < bestSize):
        result = i
        bestOverlap = common
        bestSize = size
        foundOverlap = true
    elif not foundOverlap:
      let distance = centerDistance(target, window)
      if distance < bestDistance:
        result = i
        bestDistance = distance

proc initialZone*(zones: openArray[Zone]; area, window: Box;
    occupied: openArray[bool]): int =
  ## Prefer an unoccupied zone and choose the one whose dimensions most
  ## closely match the window. Declaration order breaks exact ties.
  result = -1
  if not area.valid or not window.valid: return
  var free = false
  for i in 0 ..< zones.len:
    if i >= occupied.len or not occupied[i]:
      free = true
      break
  var bestSize = Inf
  for i, zone in zones:
    if free and i < occupied.len and occupied[i]: continue
    let target = zone.zoneBox(area)
    if not target.valid: continue
    let size = sizeDifference(target, window)
    if size < bestSize:
      result = i
      bestSize = size

proc clampInt64(value, lower, upper: int64): int64 =
  if value < lower: lower elif value > upper: upper else: value

proc zonePlacement*(zone: Zone; area, window: Box; fixedSize: bool;
    border, titleHeight: int32): Box =
  ## Return the client/content rectangle. Normal windows occupy the zone
  ## after accounting for their decorations. Fixed-size windows retain their
  ## dimensions and are positioned within the usable area when possible.
  let target = zone.zoneBox(area)
  if not target.valid or not area.valid: return window
  let b = max(border.int64, 0)
  let title = max(titleHeight.int64, 0)
  let requestedWidth = max(window.width.int64, 1)
  let requestedHeight = max(window.height.int64, 1)
  var contentWidth = requestedWidth
  var contentHeight = requestedHeight
  if not fixedSize:
    contentWidth = max(1'i64, target.width.int64 - 2 * b)
    contentHeight = max(1'i64, target.height.int64 - 2 * b - title)
  let frameWidth = contentWidth + 2 * b
  let frameHeight = contentHeight + 2 * b + title
  var frameX: int64
  var frameY: int64
  if fixedSize:
    let zoneLeft = target.x.int64
    let zoneRight = zoneLeft + target.width.int64
    let zoneTop = target.y.int64
    let zoneBottom = zoneTop + target.height.int64
    let areaRight = area.x.int64 + area.width.int64
    let areaBottom = area.y.int64 + area.height.int64
    let touchesLeft = zoneLeft <= area.x.int64
    let touchesRight = zoneRight >= areaRight
    let touchesTop = zoneTop <= area.y.int64
    let touchesBottom = zoneBottom >= areaBottom
    if touchesLeft and not touchesRight:
      frameX = area.x.int64
    elif touchesRight and not touchesLeft:
      frameX = areaRight - frameWidth
    else:
      frameX = zoneLeft + (target.width.int64 - frameWidth) div 2
    if touchesTop and not touchesBottom:
      frameY = area.y.int64
    elif touchesBottom and not touchesTop:
      frameY = areaBottom - frameHeight
    else:
      frameY = zoneTop + (target.height.int64 - frameHeight) div 2
    # Keep the frame in the usable area whenever its dimensions permit it;
    # oversized frames retain their dimensions and use the area's origin.
    if frameWidth <= area.width.int64:
      frameX = clampInt64(frameX, area.x.int64, area.x.int64 + area.width.int64 - frameWidth)
    else:
      frameX = area.x.int64
    if frameHeight <= area.height.int64:
      frameY = clampInt64(frameY, area.y.int64, area.y.int64 + area.height.int64 - frameHeight)
    else:
      frameY = area.y.int64
  else:
    frameX = target.x.int64 + (target.width.int64 - frameWidth) div 2
    frameY = target.y.int64 + (target.height.int64 - frameHeight) div 2
  let contentX = frameX + b
  let contentY = frameY + b + title
  if contentX < low(int32).int64 or contentY < low(int32).int64 or
      contentX > high(int32).int64 or contentY > high(int32).int64:
    return window
  Box(x: contentX.int32, y: contentY.int32,
    width: min(contentWidth, high(int32).int64).int32,
    height: min(contentHeight, high(int32).int64).int32)
