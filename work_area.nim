# SPDX-License-Identifier: 0BSD

## Floating-window placement in an output's non-exclusive (usable) area.
type
  Box* = object
    x*, y*, width*, height*: int32

proc valid*(box: Box): bool =
  box.width > 0 and box.height > 0 and
    box.x.int64 + box.width <= high(int32) and
    box.y.int64 + box.height <= high(int32)

proc intersection*(a, b: Box): Box =
  if not a.valid or not b.valid: return
  let x = max(a.x.int64, b.x.int64)
  let y = max(a.y.int64, b.y.int64)
  let right = min(a.x.int64 + a.width, b.x.int64 + b.width)
  let bottom = min(a.y.int64 + a.height, b.y.int64 + b.height)
  if right > x and bottom > y:
    result = Box(x: x.int32, y: y.int32, width: (right - x).int32, height: (bottom - y).int32)

proc usableArea*(bounds, hint: Box): Box =
  result = intersection(bounds, hint)
  if not result.valid: result = bounds

proc contains*(box: Box; x, y: int32): bool =
  box.valid and x >= box.x and y >= box.y and
    x.int64 < box.x.int64 + box.width and y.int64 < box.y.int64 + box.height

proc overlap*(a, b: Box): int64 =
  let common = intersection(a, b)
  common.width.int64 * common.height

proc fitPosition*(area: Box; x, y, width, height, border, titleHeight: int32): tuple[x, y: int32] =
  ## Keep the whole frame inside when it fits. For oversized windows, prefer
  ## keeping the titlebar reachable rather than shrinking/forcing client sizes.
  result = (x, y)
  if not area.valid: return
  let left = min(area.x.int64 + border, area.x.int64 + area.width - 1)
  let top = min(area.y.int64 + border + titleHeight, area.y.int64 + area.height - 1)
  let right = max(left, area.x.int64 + area.width - border - max(width, 1))
  let bottom = max(top, area.y.int64 + area.height - border - max(height, 1))
  result = (clamp(x.int64, left, right).int32, clamp(y.int64, top, bottom).int32)
