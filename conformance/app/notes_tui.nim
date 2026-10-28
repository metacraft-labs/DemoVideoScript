## The conformance application's terminal build: the headless core
## (notes_core.nim) on a real terminal.
##
##   notes-tui [--fixture FILE] [--width W --height H] [--clock | --clock-at HH:MM:SS]
##
## `--clock` shows the time of day in the title row; `--clock-at` shows a
## stopped clock.
##
## It draws the core's cells with ANSI sequences on the alternate screen,
## enables SGR mouse reporting with any-motion tracking (DEC 1003, 1006) so
## clicks, drags, hovers and the wheel arrive, reads raw input, and feeds it
## through `decodeTerminalInput` — the same decoder the reference backend
## uses. Asynchronous operations complete on a timer, as in the other builds.
## The screen is redrawn whenever the core's state may have changed.

import std/[json, os, posix, termios, monotimes, times, strutils, exitprocs]
import ./notes_core

var saved: Termios

proc rawMode() =
  discard tcGetAttr(0, addr saved)
  var t = saved
  t.c_iflag = t.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  t.c_oflag = t.c_oflag and not Cflag(OPOST)
  t.c_cflag = t.c_cflag or Cflag(CS8)
  t.c_lflag = t.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
  t.c_cc[VMIN] = 0.char
  t.c_cc[VTIME] = 0.char
  discard tcSetAttr(0, TCSAFLUSH, addr t)

proc restore() {.noconv.} =
  stdout.write "\e[?1003l\e[?1006l\e[?25h\e[?1049l"
  stdout.flushFile()
  discard tcSetAttr(0, TCSAFLUSH, addr saved)

proc draw(app: App) =
  var o = "\e[?25l\e[H"
  for r, row in app.render:
    o.add "\e[" & $(r + 1) & ";1H"
    var rev = false
    var bold = false
    for c in row:
      if c.reverse != rev or c.bold != bold:
        o.add "\e[0m"
        if c.reverse: o.add "\e[7m"
        if c.bold: o.add "\e[1m"
        rev = c.reverse
        bold = c.bold
      o.add c.text
    o.add "\e[0m"
  let (cr, cc) = app.cursorCell
  if cr >= 0: o.add "\e[" & $(cr + 1) & ";" & $(cc + 1) & "H\e[?25h"
  stdout.write o
  stdout.flushFile()

proc main() =
  var fixture = ""
  var width = 60
  var height = 16
  var clock: proc (): string {.closure.} = nil
  var k = 1
  while k <= paramCount():
    case paramStr(k)
    of "--fixture": (inc k; fixture = paramStr(k))
    of "--width": (inc k; width = parseInt(paramStr(k)))
    of "--height": (inc k; height = parseInt(paramStr(k)))
    of "--clock": clock = liveClock()
    of "--clock-at": (inc k; clock = fixedClock(paramStr(k)))
    else:
      stderr.writeLine "usage: notes-tui [--fixture FILE] [--width W --height H] [--clock | --clock-at HH:MM:SS]"
      quit 64
    inc k
  let t0 = getMonoTime()
  let app = newApp(width, height, proc (): int64 = (getMonoTime() - t0).inMilliseconds)
  if fixture.len > 0: app.loadNotes(parseFile(fixture))
  app.wallClock = clock
  rawMode()
  addExitProc(proc () = restore())
  stdout.write "\e[?1049h\e[2J\e[?1003h\e[?1006h"
  app.draw()
  var buf = ""
  var chunk = newString(4096)
  var lastScreen = app.screenText
  while true:
    var pfd = TPollfd(fd: 0, events: POLLIN)
    let ready = poll(addr pfd, 1, 20)
    if ready > 0 and (pfd.revents and POLLIN) != 0:
      let n = read(0, addr chunk[0], chunk.len)
      if n <= 0: break
      buf.add chunk[0 ..< n]
      # an ESC alone at the end of a read may be the start of a sequence
      # that has not arrived yet; give it a moment before calling it Esc
      if buf.len > 0 and buf[^1] == '\e':
        var p2 = TPollfd(fd: 0, events: POLLIN)
        if poll(addr p2, 1, 30) > 0: continue
      for e in decodeTerminalInput(buf):
        if e.kind == evChar and e.ch == "q" and mkCtrl in e.mods: quit 0
        app.handle(e)
    app.tick()
    let screen = app.screenText
    if ready > 0 or screen != lastScreen:
      app.draw()
      lastScreen = screen

main()
