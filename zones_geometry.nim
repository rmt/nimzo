# SPDX-License-Identifier: 0BSD

# Convert percentage zones into rectangles, choose zones for windows, and
# calculate frame placement without compositor state.

import std/[math, options]

type
  ZoneDef* = object
    name*: string
    x*, y*, width*, height*: float64

  ZoneBox* = object
    x*, y*, width*, height*: int32

proc valid(box: ZoneBox): bool {.inline.} =
  box.width > 0 and box.height > 0

proc finite(value: float64): bool {.inline.} =
  value.classify notin {fcNan, fcInf, fcNegInf}

proc zoneCoordinate(value: float64; origin, extent: int32): int64 {.inline.} =
  ## Calculate edges rather than widths so adjacent zones share an edge.
  origin.int64 + floor(value * extent.float64 / 100.0 + 0.5).int64

proc zoneBox*(zone: ZoneDef; area: ZoneBox): ZoneBox =
  if not finite(zone.x) or not finite(zone.y) or not finite(zone.width) or
      not finite(zone.height) or zone.x < 0 or zone.y < 0 or zone.width <= 0 or
      zone.height <= 0 or zone.x + zone.width > 100 or
      zone.y + zone.height > 100 or not area.valid:
    return
  let left = zoneCoordinate(zone.x, area.x, area.width)
  let top = zoneCoordinate(zone.y, area.y, area.height)
  let right = zoneCoordinate(zone.x + zone.width, area.x, area.width)
  let bottom = zoneCoordinate(zone.y + zone.height, area.y, area.height)
  if right <= left or bottom <= top or left < low(int32).int64 or
      top < low(int32).int64 or right > high(int32).int64 or
      bottom > high(int32).int64:
    return
  ZoneBox(x: left.int32, y: top.int32, width: (right - left).int32,
    height: (bottom - top).int32)

proc sizeDifference(target, window: ZoneBox): float64 {.inline.} =
  let widthScale = max(target.width.float64, max(window.width.float64, 1.0))
  let heightScale = max(target.height.float64, max(window.height.float64, 1.0))
  abs(target.width.float64 - window.width.float64) / widthScale +
    abs(target.height.float64 - window.height.float64) / heightScale

proc centerDistance(a, b: ZoneBox): float64 {.inline.} =
  let ax = a.x.float64 + a.width.float64 / 2.0
  let ay = a.y.float64 + a.height.float64 / 2.0
  let bx = b.x.float64 + b.width.float64 / 2.0
  let by = b.y.float64 + b.height.float64 / 2.0
  let dx = ax - bx
  let dy = ay - by
  dx * dx + dy * dy

proc overlapSize(a, b: ZoneBox): int64 {.inline.} =
  let left = max(a.x.int64, b.x.int64)
  let top = max(a.y.int64, b.y.int64)
  let right = min(a.x.int64 + a.width.int64, b.x.int64 + b.width.int64)
  let bottom = min(a.y.int64 + a.height.int64, b.y.int64 + b.height.int64)
  if right <= left or bottom <= top: 0 else: (right - left) * (bottom - top)

proc bestOverlappingZone*(zones: openArray[ZoneDef]; area, window: ZoneBox;
    current: int): int =
  ## Require positive overlap. Keep the current zone on a tie.
  result = -1
  if not area.valid or not window.valid: return
  var bestOverlap = 0'i64
  for i, zone in zones:
    let target = zone.zoneBox(area)
    if not target.valid: continue
    let overlap = overlapSize(target, window)
    if overlap > bestOverlap or (overlap > 0 and overlap == bestOverlap and i == current):
      bestOverlap = overlap
      result = i

proc bestZone*(zones: openArray[ZoneDef]; area, window: ZoneBox;
    dropPoint = none(tuple[x, y: float64])): int =
  ## Prefer zones under the drop point, when supplied. Otherwise use frame overlap.
  ## Break overlap ties by closest dimensions, or use nearest centre if none overlap.
  result = -1
  if not area.valid or not window.valid: return
  var foundUnderPointer = false
  var foundOverlap = false
  var bestOverlap: int64 = -1
  var bestSize = Inf
  var bestDistance = Inf
  for i, zone in zones:
    let target = zone.zoneBox(area)
    if not target.valid: continue
    if dropPoint.isSome:
      let (x, y) = dropPoint.get
      let underPointer = x >= target.x.float64 and y >= target.y.float64 and
        x < target.x.float64 + target.width.float64 and
        y < target.y.float64 + target.height.float64
      if foundUnderPointer and not underPointer: continue
      if underPointer and not foundUnderPointer:
        # Discard the fallback when the first zone under the pointer is found.
        foundUnderPointer = true
        foundOverlap = false
        bestDistance = Inf
    let common = overlapSize(target, window)
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

proc initialZone*(zones: openArray[ZoneDef]; area, window: ZoneBox;
    occupied: openArray[bool]): int =
  ## Prefer an unoccupied zone, and within that set choose closest dimensions.
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

proc clampInt64(value, lower, upper: int64): int64 {.inline.} =
  if value < lower: lower elif value > upper: upper else: value

proc zonePlacement*(zone: ZoneDef; area, window: ZoneBox;
    fixedSize: bool): ZoneBox =
  ## Return the outer frame. Normal windows fill the zone; fixed-size windows
  ## retain their dimensions and align to zone edges or centre as appropriate.
  let target = zone.zoneBox(area)
  if not target.valid or not area.valid: return window
  let requestedWidth = max(window.width.int64, 1)
  let requestedHeight = max(window.height.int64, 1)
  var frameWidth = requestedWidth
  var frameHeight = requestedHeight
  if not fixedSize:
    frameWidth = target.width.int64
    frameHeight = target.height.int64
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
    if frameWidth <= area.width.int64:
      frameX = clampInt64(frameX, area.x.int64,
        area.x.int64 + area.width.int64 - frameWidth)
    else:
      frameX = area.x.int64
    if frameHeight <= area.height.int64:
      frameY = clampInt64(frameY, area.y.int64,
        area.y.int64 + area.height.int64 - frameHeight)
    else:
      frameY = area.y.int64
  else:
    frameX = target.x.int64
    frameY = target.y.int64
  if frameX < low(int32).int64 or frameY < low(int32).int64 or
      frameX > high(int32).int64 or frameY > high(int32).int64 or
      frameWidth > high(int32).int64 or frameHeight > high(int32).int64:
    return window
  ZoneBox(x: frameX.int32, y: frameY.int32, width: frameWidth.int32,
    height: frameHeight.int32)

proc zoneIndex*(zones: openArray[ZoneDef]; name: string): int =
  for i, zone in zones:
    if zone.name == name: return i
  -1
