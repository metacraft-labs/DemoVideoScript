## `dvs-refapp` — the reference backend served over JSON lines on stdio.
##
##   dvs-refapp [--defect=stale-read|off-by-one|early-sync|read-side-effect]
##              [--without=CAPABILITY,…]   withhold capabilities

import std/[os, strutils]

import demo_video_script/[backend, jsonlines]
import ./refapp_backend

when isMainModule:
  var defect = dfNone
  var without: seq[string]
  for a in commandLineParams():
    if a.startsWith("--defect="): defect = parseEnum[PlantedDefect](a[9 .. ^1])
    elif a.startsWith("--without="): without.add a[10 .. ^1].split(',')
    else:
      stderr.writeLine "usage: dvs-refapp [--defect=stale-read|off-by-one|early-sync|read-side-effect]"
      quit 64
  serveJsonLines(newRefappBackend(defect, without))
