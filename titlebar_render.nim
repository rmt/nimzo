# Render scaled titlebars with Pango and Cairo into wlroots pixel buffers.

# Keep GLib/Pango headers in a separate translation unit from the compositor ABI.
import std/math
import runtime_config, bindings

const
  TitlebarHeight* = 24.cint
  TitlebarPadding = 8.cint
  TitlebarPangoScale = 1024.cint
  TitlebarPangoEllipsizeEnd = 3.cint
  TitlebarCairoFormatArgb32 = 0.cint
  TitlebarDrmFormatArgb8888 = 0x34325241'u32

type
  TitlebarCairoSurface {.importc: "cairo_surface_t", header: "cairo.h", incompleteStruct.} = object
  TitlebarCairoContext {.importc: "cairo_t", header: "cairo.h", incompleteStruct.} = object
  TitlebarPangoLayout {.importc: "PangoLayout", header: "pango/pangocairo.h", incompleteStruct.} = object
  TitlebarPangoFontDescription {.importc: "PangoFontDescription", header: "pango/pangocairo.h", incompleteStruct.} = object

  TitlebarBuffer = object
    base: wlr_buffer
    pixels: ptr uint32
    stride: csize_t

  TitlebarBufferImpl = object
    destroy: proc(buffer: ptr wlr_buffer) {.cdecl.}
    getDmabuf: proc(buffer: ptr wlr_buffer; attributes: pointer): bool {.cdecl.}
    getShm: proc(buffer: ptr wlr_buffer; attributes: pointer): bool {.cdecl.}
    beginDataPtrAccess: proc(buffer: ptr wlr_buffer; flags: uint32;
      data: ptr pointer; format: ptr uint32; stride: ptr csize_t): bool {.cdecl.}
    endDataPtrAccess: proc(buffer: ptr wlr_buffer) {.cdecl.}

proc malloc(size: csize_t): pointer {.importc, header: "stdlib.h".}

proc wlr_buffer_init(buffer: ptr wlr_buffer; impl: ptr wlr_buffer_impl;
  width, height: cint) {.importc.}
proc wlr_buffer_drop(buffer: ptr wlr_buffer) {.importc.}
proc wlr_buffer_finish(buffer: ptr wlr_buffer) {.importc.}

proc cairo_image_surface_create_for_data(data: ptr uint8; format, width, height,
  stride: cint): ptr TitlebarCairoSurface {.importc, header: "cairo.h".}
proc cairo_surface_status(surface: ptr TitlebarCairoSurface): cint {.importc,
  header: "cairo.h".}
proc cairo_surface_destroy(surface: ptr TitlebarCairoSurface) {.importc,
  header: "cairo.h".}
proc cairo_surface_flush(surface: ptr TitlebarCairoSurface) {.importc,
  header: "cairo.h".}
proc cairo_create(surface: ptr TitlebarCairoSurface): ptr TitlebarCairoContext {.importc,
  header: "cairo.h".}
proc cairo_status(context: ptr TitlebarCairoContext): cint {.importc,
  header: "cairo.h".}
proc cairo_destroy(context: ptr TitlebarCairoContext) {.importc, header: "cairo.h".}
proc cairo_scale(context: ptr TitlebarCairoContext; x, y: cdouble) {.importc,
  header: "cairo.h".}
proc cairo_set_source_rgba(context: ptr TitlebarCairoContext; r, g, b, a: cdouble) {.importc,
  header: "cairo.h".}
proc cairo_move_to(context: ptr TitlebarCairoContext; x, y: cdouble) {.importc,
  header: "cairo.h".}
proc cairo_line_to(context: ptr TitlebarCairoContext; x, y: cdouble) {.importc, header: "cairo.h".}
proc cairo_rectangle(context: ptr TitlebarCairoContext; x, y, width, height: cdouble) {.importc,
  header: "cairo.h".}
proc cairo_clip(context: ptr TitlebarCairoContext) {.importc, header: "cairo.h".}
proc cairo_stroke(context: ptr TitlebarCairoContext) {.importc, header: "cairo.h".}
proc cairo_translate(context: ptr TitlebarCairoContext; x, y: cdouble) {.importc, header: "cairo.h".}
proc cairo_set_line_width(context: ptr TitlebarCairoContext; width: cdouble) {.importc, header: "cairo.h".}
proc cairo_set_source_surface(context: ptr TitlebarCairoContext; surface: ptr TitlebarCairoSurface;
  x, y: cdouble) {.importc, header: "cairo.h".}
proc cairo_paint(context: ptr TitlebarCairoContext) {.importc, header: "cairo.h".}
proc cairo_image_surface_create_from_png(path: cstring): ptr TitlebarCairoSurface {.importc, header: "cairo.h".}
proc cairo_image_surface_get_width(surface: ptr TitlebarCairoSurface): cint {.importc, header: "cairo.h".}
proc cairo_image_surface_get_height(surface: ptr TitlebarCairoSurface): cint {.importc, header: "cairo.h".}
proc cairo_save(context: ptr TitlebarCairoContext) {.importc, header: "cairo.h".}
proc cairo_restore(context: ptr TitlebarCairoContext) {.importc, header: "cairo.h".}
proc pango_cairo_create_layout(context: ptr TitlebarCairoContext): ptr TitlebarPangoLayout {.importc,
  header: "pango/pangocairo.h".}
proc pango_cairo_show_layout(context: ptr TitlebarCairoContext;
  layout: ptr TitlebarPangoLayout) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_set_text(layout: ptr TitlebarPangoLayout; text: cstring;
  length: cint) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_set_font_description(layout: ptr TitlebarPangoLayout;
  description: ptr TitlebarPangoFontDescription) {.importc,
  header: "pango/pangocairo.h".}
proc pango_layout_set_width(layout: ptr TitlebarPangoLayout; width: cint) {.importc,
  header: "pango/pangocairo.h".}
proc pango_layout_set_ellipsize(layout: ptr TitlebarPangoLayout; mode: cint) {.importc,
  header: "pango/pangocairo.h".}
proc pango_layout_set_single_paragraph_mode(layout: ptr TitlebarPangoLayout;
  setting: cint) {.importc, header: "pango/pangocairo.h".}
proc pango_layout_get_pixel_size(layout: ptr TitlebarPangoLayout; width, height: ptr cint) {.importc,
  header: "pango/pangocairo.h".}
proc pango_font_description_from_string(description: cstring): ptr TitlebarPangoFontDescription {.importc,
  header: "pango/pangocairo.h".}
proc pango_font_description_free(description: ptr TitlebarPangoFontDescription) {.importc,
  header: "pango/pangocairo.h".}
proc g_object_unref(obj: pointer) {.importc, header: "glib-object.h".}
proc g_utf8_validate(text: cstring; maxLength: clong; endPointer: pointer): bool {.importc,
  header: "glib.h".}

var titlebarBufferImpl {.global.}: TitlebarBufferImpl

proc titlebarReportFailure(message: string) {.inline.} =
  stderr.writeLine("titlebar: ", message)

proc titlebarChannel(value: cfloat): uint32 {.inline.} =
  if value <= 0: return 0
  if value >= 1: return 255
  uint32(value * 255.cfloat + 0.5.cfloat)

proc titlebarPixel(color: Color): uint32 {.inline.} =
  let r = titlebarChannel(color[0])
  let g = titlebarChannel(color[1])
  let b = titlebarChannel(color[2])
  let a = titlebarChannel(color[3])
  (a shl 24) or (r shl 16) or (g shl 8) or b

proc titlebarUnpremultiplied(value, alpha: cfloat): cdouble {.inline.} =
  if alpha <= 0: 0.cdouble
  elif value <= 0: 0.cdouble
  elif value >= alpha: 1.cdouble
  else: (value / alpha).cdouble

proc titlebarBufferDestroy(buffer: ptr wlr_buffer) {.cdecl.} =
  if buffer == nil:
    return
  let owner = cast[ptr TitlebarBuffer](buffer)
  wlr_buffer_finish(addr owner.base)
  if owner.pixels != nil:
    free(cast[pointer](owner.pixels))
    owner.pixels = nil
  free(cast[pointer](owner))

proc titlebarBufferBeginDataPtrAccess(buffer: ptr wlr_buffer; flags: uint32;
    data: ptr pointer; format: ptr uint32; stride: ptr csize_t): bool {.cdecl.} =
  if (flags and 2'u32) != 0: return false # Immutable after publication.
  if buffer == nil or data == nil or format == nil or stride == nil:
    return false
  let owner = cast[ptr TitlebarBuffer](buffer)
  if owner.pixels == nil:
    return false
  data[] = cast[pointer](owner.pixels)
  format[] = TitlebarDrmFormatArgb8888
  stride[] = owner.stride
  true

proc titlebarBufferEndDataPtrAccess(buffer: ptr wlr_buffer) {.cdecl.} =
  discard

proc initTitlebarBufferImpl() =
  titlebarBufferImpl.destroy = titlebarBufferDestroy
  titlebarBufferImpl.beginDataPtrAccess = titlebarBufferBeginDataPtrAccess
  titlebarBufferImpl.endDataPtrAccess = titlebarBufferEndDataPtrAccess

initTitlebarBufferImpl()

proc dropTitlebarBuffer*(buffer: pointer) =
  wlr_buffer_drop(cast[ptr wlr_buffer](buffer))

type CaptionIcon = enum PlainCaption, StackCaption, AppCaption

proc drawCaptionIcon(context: ptr TitlebarCairoContext; icon: CaptionIcon; iconPath: cstring) =
  if icon == AppCaption and iconPath != nil and iconPath[0] != '\0':
    let image = cairo_image_surface_create_from_png(iconPath)
    if cairo_surface_status(image) == 0:
      let width = cairo_image_surface_get_width(image)
      let height = cairo_image_surface_get_height(image)
      if width > 0 and height > 0:
        let scale = 16.0 / max(width, height).cdouble
        cairo_save(context)
        cairo_translate(context, 8.0 + (16.0 - width.cdouble * scale) / 2,
          4.0 + (16.0 - height.cdouble * scale) / 2)
        cairo_scale(context, scale, scale)
        cairo_set_source_surface(context, image, 0, 0)
        cairo_paint(context)
        cairo_restore(context)
        cairo_surface_destroy(image)
        return
    cairo_surface_destroy(image)
  cairo_set_line_width(context, 1)
  if icon == StackCaption:
    cairo_rectangle(context, 7.5, 9.5, 11, 8)
    cairo_move_to(context, 10.5, 7.5)
    cairo_line_to(context, 21.5, 7.5)
    cairo_line_to(context, 21.5, 15.5)
  else:
    cairo_rectangle(context, 8.5, 5.5, 15, 13)
    cairo_move_to(context, 8.5, 9.5)
    cairo_line_to(context, 23.5, 9.5)
  cairo_stroke(context)

proc renderCaption(width: cint; scale: cfloat; font, title: cstring;
    background, text, border: Color; borderWidth: cint;
    icon: CaptionIcon; iconPath: cstring = nil; rightInset = 0.cint): pointer =
  if width <= 0:
    titlebarReportFailure("invalid titlebar width")
    return nil
  if scale <= 0 or scale != scale:
    titlebarReportFailure("invalid titlebar scale")
    return nil
  if borderWidth < 0:
    titlebarReportFailure("invalid titlebar border width")
    return nil
  let scaleCeil = ceil(scale.float64)
  if scaleCeil < 1 or scaleCeil > high(cint).float64:
    titlebarReportFailure("titlebar scale is out of range")
    return nil
  let pixelScale = cint(scaleCeil)
  if width > high(cint) div pixelScale or TitlebarHeight > high(cint) div pixelScale:
    titlebarReportFailure("titlebar dimensions overflow")
    return nil
  let pixelWidth = width * pixelScale
  let pixelHeight = TitlebarHeight * pixelScale
  if pixelWidth > high(cint) div 4:
    titlebarReportFailure("titlebar stride overflows cairo")
    return nil
  let pixelCountLimit = high(int64) div 4
  if int64(pixelWidth) > pixelCountLimit div int64(pixelHeight):
    titlebarReportFailure("titlebar allocation is too large")
    return nil
  let bytes = csize_t(int64(pixelWidth) * int64(pixelHeight) * 4)
  let owner = cast[ptr TitlebarBuffer](calloc(1, csize_t(sizeof(TitlebarBuffer))))
  if owner == nil:
    titlebarReportFailure("failed to allocate titlebar buffer")
    return nil
  owner.pixels = cast[ptr uint32](malloc(bytes))
  if owner.pixels == nil:
    titlebarReportFailure("failed to allocate titlebar pixels")
    free(cast[pointer](owner))
    return nil
  owner.stride = csize_t(pixelWidth) * 4
  wlr_buffer_init(addr owner.base,
    cast[ptr wlr_buffer_impl](addr titlebarBufferImpl), pixelWidth, pixelHeight)

  let backgroundPixel = titlebarPixel(background)
  let borderPixel = titlebarPixel(border)
  let pixels = cast[ptr UncheckedArray[uint32]](owner.pixels)
  let borderPixels = borderWidth * pixelScale
  for y in 0 ..< pixelHeight.int:
    let row = y * pixelWidth.int
    let isHorizontalBorder = y < borderPixels or y >= pixelHeight - borderPixels
    for x in 0 ..< pixelWidth.int:
      if isHorizontalBorder or x < borderPixels or x >= pixelWidth.int - borderPixels.int:
        pixels[row + x] = borderPixel
      else:
        pixels[row + x] = backgroundPixel

  let textX = if icon == PlainCaption: TitlebarPadding else: 30.cint
  let textWidth = width - textX - TitlebarPadding - rightInset
  if title == nil or title[0] == '\0' or textWidth <= 0:
    return cast[pointer](addr owner.base)
  if not g_utf8_validate(title, -1, nil):
    titlebarReportFailure("title is not valid UTF-8")
    wlr_buffer_drop(addr owner.base)
    return nil
  if font == nil:
    titlebarReportFailure("font is missing")
    wlr_buffer_drop(addr owner.base)
    return nil
  if textWidth > high(cint) div TitlebarPangoScale:
    titlebarReportFailure("title layout width overflows Pango")
    wlr_buffer_drop(addr owner.base)
    return nil

  let surface = cairo_image_surface_create_for_data(cast[ptr uint8](owner.pixels),
    TitlebarCairoFormatArgb32, pixelWidth, pixelHeight, pixelWidth * 4)
  if surface == nil or cairo_surface_status(surface) != 0:
    if surface != nil: cairo_surface_destroy(surface)
    titlebarReportFailure("failed to create Cairo surface")
    wlr_buffer_drop(addr owner.base)
    return nil
  let context = cairo_create(surface)
  if context == nil or cairo_status(context) != 0:
    if context != nil: cairo_destroy(context)
    cairo_surface_destroy(surface)
    titlebarReportFailure("failed to create Cairo context")
    wlr_buffer_drop(addr owner.base)
    return nil
  cairo_scale(context, pixelScale.cdouble, pixelScale.cdouble)
  let layout = pango_cairo_create_layout(context)
  if layout == nil:
    cairo_destroy(context)
    cairo_surface_destroy(surface)
    titlebarReportFailure("failed to create Pango layout")
    wlr_buffer_drop(addr owner.base)
    return nil
  let description = pango_font_description_from_string(font)
  if description == nil:
    g_object_unref(cast[pointer](layout))
    cairo_destroy(context)
    cairo_surface_destroy(surface)
    titlebarReportFailure("failed to parse titlebar font")
    wlr_buffer_drop(addr owner.base)
    return nil
  pango_layout_set_font_description(layout, description)
  pango_font_description_free(description)
  pango_layout_set_text(layout, title, -1)
  pango_layout_set_width(layout, textWidth * TitlebarPangoScale)
  pango_layout_set_ellipsize(layout, TitlebarPangoEllipsizeEnd)
  pango_layout_set_single_paragraph_mode(layout, 1)
  var textHeight: cint
  pango_layout_get_pixel_size(layout, nil, addr textHeight)
  cairo_rectangle(context, borderWidth.cdouble, borderWidth.cdouble,
    (width - 2 * borderWidth).cdouble, (TitlebarHeight - 2 * borderWidth).cdouble)
  cairo_clip(context)
  let textAlpha = if text[3] <= 0: 0.cfloat elif text[3] >= 1: 1.cfloat else: text[3]
  cairo_set_source_rgba(context,
    titlebarUnpremultiplied(text[0], textAlpha),
    titlebarUnpremultiplied(text[1], textAlpha),
    titlebarUnpremultiplied(text[2], textAlpha), textAlpha.cdouble)
  if icon != PlainCaption: drawCaptionIcon(context, icon, iconPath)
  cairo_move_to(context, textX.cdouble,
    (TitlebarHeight - textHeight).cdouble / 2)
  pango_cairo_show_layout(context, layout)
  let renderStatus = cairo_status(context) == 0
  g_object_unref(cast[pointer](layout))
  cairo_destroy(context)
  cairo_surface_flush(surface)
  let surfaceStatus = cairo_surface_status(surface) == 0
  cairo_surface_destroy(surface)
  if not renderStatus or not surfaceStatus:
    titlebarReportFailure("failed to render title")
    wlr_buffer_drop(addr owner.base)
    return nil
  cast[pointer](addr owner.base)

proc renderTitlebarBuffer*(width: cint; scale: cfloat; font, title: cstring;
    background, text, border: Color; borderWidth: cint; rightInset = 0.cint): pointer =
  renderCaption(width, scale, font, title, background, text, border, borderWidth, PlainCaption,
    rightInset = rightInset)

proc renderStackCaption*(width: cint; scale: cfloat; font, title: cstring;
    colors: ClientColors; badge = false; iconPath: cstring = nil): pointer =
  renderCaption(width, scale, font, title, colors.background, colors.text,
    colors.titlebarBorder, 1, if badge: StackCaption else: AppCaption, iconPath)
