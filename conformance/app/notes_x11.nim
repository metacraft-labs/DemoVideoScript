## The conformance application's native-window build: the headless core
## (notes_core.nim) in an X11 window, drawn with Xlib.
##
##   notes-x11 [--fixture FILE] [--width W --height H]
##
## The cells are drawn in the core `fixed` font into an off-screen pixmap and
## put on the window scaled by an integer factor (pixel replication), black on
## white, so a backend reading the window by OCR reads it reliably whatever
## fonts the X server has. X pointer and key
## events become the core's input events at the cell under the pointer, so the
## window behaves as the terminal and web builds do. The window's title is
## "Notes". Links against libX11 (`-lX11`).

import std/[json, os, strutils, monotimes, times]
import ./notes_core

{.passl: "-lX11".}

type
  Display {.importc: "Display", header: "<X11/Xlib.h>", incompleteStruct.} = object
  XWindow = culong
  GC = pointer
  KeySym = culong
  XFontStruct {.importc: "XFontStruct", header: "<X11/Xlib.h>".} = object
    fid: culong
    ascent, descent: cint
    max_bounds: XCharStruct
  XCharStruct {.importc: "XCharStruct", header: "<X11/Xlib.h>".} = object
    width: cshort
  XEvent {.importc: "XEvent", header: "<X11/Xlib.h>", union.} = object
    theType {.importc: "type".}: cint
    xbutton: XButtonEvent
    xmotion: XMotionEvent
    xkey: XKeyEvent
    pad: array[24, clong]
  XButtonEvent {.importc: "XButtonEvent", header: "<X11/Xlib.h>".} = object
    x, y: cint
    state: cuint
    button: cuint
  XMotionEvent {.importc: "XMotionEvent", header: "<X11/Xlib.h>".} = object
    x, y: cint
    state: cuint
  XKeyEvent {.importc: "XKeyEvent", header: "<X11/Xlib.h>".} = object
    state: cuint
    keycode: cuint

const
  KeyPress = 2.cint
  ButtonPress = 4.cint
  ButtonRelease = 5.cint
  MotionNotify = 6.cint
  Expose = 12.cint
  ExposureMask = 1 shl 15
  KeyPressMask = 1 shl 0
  ButtonPressMask = 1 shl 2
  ButtonReleaseMask = 1 shl 3
  PointerMotionMask = 1 shl 6
  ShiftMask = 1'u32
  ControlMask = 4'u32
  Mod1Mask = 8'u32
  Mod4Mask = 64'u32
  Button1Mask = 1'u32 shl 8
  Button2Mask = 1'u32 shl 9
  Button3Mask = 1'u32 shl 10

proc XOpenDisplay(name: cstring): ptr Display {.importc, header: "<X11/Xlib.h>".}
proc XDefaultScreen(d: ptr Display): cint {.importc, header: "<X11/Xlib.h>".}
proc XRootWindow(d: ptr Display; s: cint): XWindow {.importc, header: "<X11/Xlib.h>".}
proc XBlackPixel(d: ptr Display; s: cint): culong {.importc, header: "<X11/Xlib.h>".}
proc XWhitePixel(d: ptr Display; s: cint): culong {.importc, header: "<X11/Xlib.h>".}
proc XCreateSimpleWindow(d: ptr Display; parent: XWindow; x, y: cint; w, h, bw: cuint;
                         border, bg: culong): XWindow {.importc, header: "<X11/Xlib.h>".}
proc XStoreName(d: ptr Display; w: XWindow; name: cstring): cint {.importc, header: "<X11/Xlib.h>".}
proc XSelectInput(d: ptr Display; w: XWindow; mask: clong): cint {.importc, header: "<X11/Xlib.h>".}
proc XMapWindow(d: ptr Display; w: XWindow): cint {.importc, header: "<X11/Xlib.h>".}
proc XCreateGC(d: ptr Display; w: XWindow; mask: culong; v: pointer): GC {.importc, header: "<X11/Xlib.h>".}
proc XLoadQueryFont(d: ptr Display; name: cstring): ptr XFontStruct {.importc, header: "<X11/Xlib.h>".}
proc XSetFont(d: ptr Display; gc: GC; font: culong): cint {.importc, header: "<X11/Xlib.h>".}
proc XSetForeground(d: ptr Display; gc: GC; c: culong): cint {.importc, header: "<X11/Xlib.h>".}
proc XFillRectangle(d: ptr Display; w: XWindow; gc: GC; x, y: cint; wd, h: cuint): cint {.importc, header: "<X11/Xlib.h>".}
proc XDrawString(d: ptr Display; w: XWindow; gc: GC; x, y: cint; s: cstring; n: cint): cint {.importc, header: "<X11/Xlib.h>".}
proc XPending(d: ptr Display): cint {.importc, header: "<X11/Xlib.h>".}
proc XNextEvent(d: ptr Display; e: ptr XEvent): cint {.importc, header: "<X11/Xlib.h>".}
proc XFlush(d: ptr Display): cint {.importc, header: "<X11/Xlib.h>".}
proc XLookupString(e: ptr XKeyEvent; buf: cstring; n: cint; ks: ptr KeySym; st: pointer): cint {.importc, header: "<X11/Xutil.h>".}
proc XConnectionNumber(d: ptr Display): cint {.importc, header: "<X11/Xlib.h>".}
type XImage {.importc: "XImage", header: "<X11/Xlib.h>", incompleteStruct.} = object
proc XCreatePixmap(d: ptr Display; w: XWindow; wd, h, depth: cuint): XWindow {.importc, header: "<X11/Xlib.h>".}
proc XDefaultDepth(d: ptr Display; s: cint): cint {.importc, header: "<X11/Xlib.h>".}
proc XDefaultVisual(d: ptr Display; s: cint): pointer {.importc, header: "<X11/Xlib.h>".}
proc XGetImage(d: ptr Display; w: XWindow; x, y: cint; wd, h: cuint; planes: culong;
               format: cint): ptr XImage {.importc, header: "<X11/Xlib.h>".}
proc XCreateImage(d: ptr Display; v: pointer; depth: cuint; format, offset: cint; data: pointer;
                  wd, h: cuint; pad, bpl: cint): ptr XImage {.importc, header: "<X11/Xlib.h>".}
proc XGetPixel(i: ptr XImage; x, y: cint): culong {.importc, header: "<X11/Xutil.h>".}
proc XPutPixel(i: ptr XImage; x, y: cint; p: culong): cint {.importc, header: "<X11/Xutil.h>".}
proc XPutImage(d: ptr Display; w: XWindow; gc: GC; i: ptr XImage; sx, sy, dx, dy: cint;
               wd, h: cuint): cint {.importc, header: "<X11/Xlib.h>".}
proc XDestroyImage(i: ptr XImage): cint {.importc, header: "<X11/Xutil.h>".}
const ZPixmap = 2.cint
const Scale = 3

const keysymNames = [(0xff0d'u, "Enter"), (0xff1b'u, "Esc"), (0xff09'u, "Tab"),
                     (0xff08'u, "Backspace"), (0xffff'u, "Delete"), (0xff63'u, "Insert"),
                     (0xff50'u, "Home"), (0xff57'u, "End"), (0xff55'u, "PageUp"),
                     (0xff56'u, "PageDown"), (0xff52'u, "Up"), (0xff54'u, "Down"),
                     (0xff51'u, "Left"), (0xff53'u, "Right")]

proc main() =
  var fixture = ""
  var width = 60
  var height = 16
  var k = 1
  while k <= paramCount():
    case paramStr(k)
    of "--fixture": (inc k; fixture = paramStr(k))
    of "--width": (inc k; width = parseInt(paramStr(k)))
    of "--height": (inc k; height = parseInt(paramStr(k)))
    else:
      stderr.writeLine "usage: notes-x11 [--fixture FILE] [--width W --height H]"
      quit 64
    inc k
  let d = XOpenDisplay(nil)
  if d == nil:
    stderr.writeLine "notes-x11: cannot open the display (is DISPLAY set?)"
    quit 2
  let scr = XDefaultScreen(d)
  var font = XLoadQueryFont(d, "-misc-fixed-medium-r-normal--20-200-75-75-c-100-iso10646-1")
  if font == nil: font = XLoadQueryFont(d, "10x20")
  if font == nil: font = XLoadQueryFont(d, "fixed")
  if font == nil:
    stderr.writeLine "notes-x11: no fixed font"
    quit 2
  let cw = int(font.max_bounds.width)
  let ch = int(font.ascent + font.descent) + 1
  let pad = 3
  let pw = width * cw + 2 * pad      # the frame at 1x
  let ph = height * ch + 2 * pad
  let w = XCreateSimpleWindow(d, XRootWindow(d, scr), 0, 0, cuint(pw * Scale),
                              cuint(ph * Scale), 0, XBlackPixel(d, scr),
                              XWhitePixel(d, scr))
  discard XStoreName(d, w, "Notes")
  discard XSelectInput(d, w, ExposureMask or KeyPressMask or ButtonPressMask or
                             ButtonReleaseMask or PointerMotionMask)
  discard XMapWindow(d, w)
  let gc = XCreateGC(d, w, 0, nil)
  let depth = XDefaultDepth(d, scr)
  let frame = XCreatePixmap(d, w, cuint(pw), cuint(ph), cuint(depth))
  var big = XCreateImage(d, XDefaultVisual(d, scr), cuint(depth), ZPixmap, 0,
                         alloc0(pw * Scale * ph * Scale * 4), cuint(pw * Scale),
                         cuint(ph * Scale), 32, 0)
  discard XSetFont(d, gc, font.fid)
  let t0 = getMonoTime()
  let app = newApp(width, height, proc (): int64 = (getMonoTime() - t0).inMilliseconds)
  if fixture.len > 0: app.loadNotes(parseFile(fixture))
  var last: seq[string]
  proc draw(force: bool) =
    let rows = app.render
    var text: seq[string]
    for row in rows:
      var line = ""
      for c in row: line.add c.text
      text.add line
    if not force and text == last: return
    last = text
    discard XSetForeground(d, gc, XWhitePixel(d, scr))
    discard XFillRectangle(d, frame, gc, 0, 0, cuint(pw), cuint(ph))
    let (cr, cc) = app.cursorCell
    for r, row in rows:
      for c, cell in row:
        let rev = cell.reverse or (r == cr and c == cc)
        let x = cint(pad + c * cw)
        let y = cint(pad + r * ch)
        if rev:
          discard XSetForeground(d, gc, XBlackPixel(d, scr))
          discard XFillRectangle(d, frame, gc, x, y, cuint(cw), cuint(ch))
          discard XSetForeground(d, gc, XWhitePixel(d, scr))
        else:
          discard XSetForeground(d, gc, XBlackPixel(d, scr))
        if cell.text != " ":
          discard XDrawString(d, frame, gc, x, y + cint(font.ascent), cstring(cell.text),
                              cint(cell.text.len))
    # scale the frame onto the window by pixel replication
    let small = XGetImage(d, frame, 0, 0, cuint(pw), cuint(ph), not 0'u, ZPixmap)
    for yy in 0 ..< ph:
      for xx in 0 ..< pw:
        let px = XGetPixel(small, cint(xx), cint(yy))
        for dy in 0 ..< Scale:
          for dx in 0 ..< Scale:
            discard XPutPixel(big, cint(xx * Scale + dx), cint(yy * Scale + dy), px)
    discard XDestroyImage(small)
    discard XPutImage(d, w, gc, big, 0, 0, 0, 0, cuint(pw * Scale), cuint(ph * Scale))
    discard XFlush(d)
  proc cellOf(x, y: cint): (int, int) =
    ((int(y) div Scale - pad) div ch, (int(x) div Scale - pad) div cw)
  proc mods(state: cuint): set[ModKey] =
    if (state and ShiftMask) != 0: result.incl mkShift
    if (state and ControlMask) != 0: result.incl mkCtrl
    if (state and Mod1Mask) != 0: result.incl mkAlt
    if (state and Mod4Mask) != 0: result.incl mkMeta
  var ev: XEvent
  while true:
    while XPending(d) > 0:
      discard XNextEvent(d, addr ev)
      case ev.theType
      of Expose: draw(true)
      of ButtonPress, ButtonRelease:
        let (row, col) = cellOf(ev.xbutton.x, ev.xbutton.y)
        let b = ev.xbutton.button
        if b in [4'u32, 5'u32]:
          if ev.theType == ButtonPress:
            app.handle(InputEvent(kind: evWheel, row: row, col: col, wheelUp: b == 4,
                                  mods: mods(ev.xbutton.state)))
        else:
          let btn = (if b == 1: mbLeft elif b == 2: mbMiddle elif b == 3: mbRight else: mbNone)
          app.handle(InputEvent(kind: (if ev.theType == ButtonPress: evPress else: evRelease),
                                row: row, col: col, button: btn, mods: mods(ev.xbutton.state)))
      of MotionNotify:
        let (row, col) = cellOf(ev.xmotion.x, ev.xmotion.y)
        let st = ev.xmotion.state
        let btn = (if (st and Button1Mask) != 0: mbLeft elif (st and Button3Mask) != 0: mbRight
                   elif (st and Button2Mask) != 0: mbMiddle else: mbNone)
        app.handle(InputEvent(kind: evMove, row: row, col: col, button: btn, mods: mods(st)))
      of KeyPress:
        var buf: array[16, char]
        var ks: KeySym
        let n = XLookupString(addr ev.xkey, cast[cstring](addr buf[0]), 16, addr ks, nil)
        var named = ""
        for (sym, name) in keysymNames:
          if uint(ks) == sym: named = name
        if ks >= 0xffbe and ks <= 0xffc9: named = "F" & $(int(ks) - 0xffbe + 1)
        let m = mods(ev.xkey.state)
        if named.len > 0:
          app.handle(InputEvent(kind: evKey, key: named, mods: m))
        elif ks >= 0x20 and ks <= 0x7e:
          var c = $chr(int(ks))
          var mm = m
          if mkCtrl in mm or mkAlt in mm: c = c.toLowerAscii
          mm.excl mkShift
          app.handle(InputEvent(kind: evChar, ch: c, mods: mm))
        elif n > 0 and buf[0] >= ' ':
          app.handle(InputEvent(kind: evChar, ch: $cast[cstring](addr buf[0]), mods: {}))
      else: discard
    app.tick()
    draw(false)
    sleep(15)

main()
