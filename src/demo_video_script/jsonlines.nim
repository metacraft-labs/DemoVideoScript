## The backend protocol over JSON lines on stdio (§6.2).
##
## `spawnJsonLinesBackend` starts a backend process and implements `Backend` by
## writing one request per line to its stdin and reading one response per line
## from its stdout. A crash, a line that is not a JSON response, a response to
## another request, or no answer before the deadline is a `BackendError` of kind
## `crashed` or `protocol` naming the backend — never a hang and never a guess.
## The backend's stderr is kept as its log.
##
## `serveJsonLines` is the other end: it hosts an in-process `Backend` on stdin
## and stdout, so an adapter written in Nim can also be reached out of process.
##
## Messages (schemas/v1/backend-protocol.schema.json):
##   request   {"id": n, "call": "<name>", …arguments}
##   response  {"id": n, "ok": true, …result} | {"id": n, "ok": false,
##             "error": {"kind": "<kind>", "message": "…"}}
## `DVS_PROTOCOL_TRANSCRIPT=<file>` makes the client append every line it sends
## (`> `) and receives (`< `) to that file.

import std/[json, os, osproc, options, posix, strutils, streams, times, monotimes]
import ./backend

type
  Conn = ref object
    p: Process
    name: string
    nextId: int
    buf: string
    errBuf: string
    transcript: File
    hasTranscript: bool
    dead: bool

proc defaultCallTimeoutMs(): int =
  ## How long a call may take before the backend is declared unresponsive;
  ## `DVS_BACKEND_TIMEOUT_MS` overrides the 30 s default.
  try: parseInt(getEnv("DVS_BACKEND_TIMEOUT_MS", "30000")) except ValueError: 30_000

proc crashed(c: Conn; msg: string): ref BackendError =
  var log = c.errBuf.strip
  if log.len > 2000: log = "…" & log[^2000 .. ^1]
  backendError(beCrashed, "backend '" & c.name & "' " & msg &
    (if log.len > 0: "; its log ends with: " & log else: ""))

proc drainErr(c: Conn) =
  let fd = c.p.errorHandle
  var pfd = TPollfd(fd: fd.cint, events: POLLIN)
  while poll(addr pfd, 1, 0) > 0 and (pfd.revents and POLLIN) != 0:
    var chunk = newString(4096)
    let n = read(fd.cint, addr chunk[0], 4096)
    if n <= 0: break
    chunk.setLen(n)
    c.errBuf.add chunk
    if c.errBuf.len > 1_000_000: c.errBuf = c.errBuf[^500_000 .. ^1]

proc readLine(c: Conn; timeoutMs: int): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  let outFd = c.p.outputHandle.cint
  let errFd = c.p.errorHandle.cint
  while true:
    let nl = c.buf.find('\n')
    if nl >= 0:
      result = c.buf[0 ..< nl]
      c.buf = c.buf[nl + 1 .. ^1]
      return
    let left = int((deadline - getMonoTime()).inMilliseconds)
    if left <= 0:
      raise c.crashed("did not answer within " & $timeoutMs & " ms")
    var fds = [TPollfd(fd: outFd, events: POLLIN), TPollfd(fd: errFd, events: POLLIN)]
    let r = poll(addr fds[0], 2, min(left, 200).cint)
    if r < 0:
      if errno == EINTR: continue
      raise c.crashed("poll failed")
    if (fds[1].revents and (POLLIN or POLLHUP)) != 0:
      var chunk = newString(4096)
      let n = read(errFd, addr chunk[0], 4096)
      if n > 0:
        chunk.setLen(n)
        c.errBuf.add chunk
    if (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
      var chunk = newString(65536)
      let n = read(outFd, addr chunk[0], 65536)
      if n <= 0:
        c.dead = true
        c.drainErr()
        let code = c.p.waitForExit(1000)
        raise c.crashed("exited" & (if code != -1: " with status " & $code else: "") &
          " without answering")
      chunk.setLen(n)
      c.buf.add chunk

proc call(c: Conn; name: string; args: JsonNode; timeoutMs = -1): JsonNode =
  if c.dead: raise c.crashed("is no longer running")
  let timeoutMs = (if timeoutMs < 0: defaultCallTimeoutMs() else: min(timeoutMs, max(defaultCallTimeoutMs(), timeoutMs)))
  inc c.nextId
  var req = (if args == nil: newJObject() else: args.copy)
  req["id"] = %c.nextId
  req["call"] = %name
  let line = $req
  if c.hasTranscript:
    c.transcript.writeLine("> " & line)
    c.transcript.flushFile()
  try:
    c.p.inputStream.write(line & "\n")
    c.p.inputStream.flush()
  except IOError, OSError:
    c.dead = true
    raise c.crashed("closed its input")
  let resp = c.readLine(timeoutMs)
  if c.hasTranscript:
    c.transcript.writeLine("< " & resp)
    c.transcript.flushFile()
  var j: JsonNode
  try: j = parseJson(resp)
  except JsonParsingError, ValueError:
    raise backendError(beProtocol, "backend '" & c.name & "' wrote a line that is not JSON: " &
      resp[0 ..< min(resp.len, 200)])
  if j.kind != JObject or j{"id"}.getInt(-1) != c.nextId or not j.hasKey("ok"):
    raise backendError(beProtocol, "backend '" & c.name & "' answered request " & $c.nextId &
      " with " & resp[0 ..< min(resp.len, 200)])
  if not j["ok"].getBool:
    let e = j{"error"}
    var kind = beInternal
    try: kind = parseEnum[BackendErrorKind](e{"kind"}.getStr("internal"))
    except ValueError: kind = beProtocol
    raise backendError(kind, e{"message"}.getStr("(no message)"))
  j

proc spawnJsonLinesBackend*(command: string; args: seq[string] = @[]; workDir = "";
                            name = ""): Backend =
  let p = startProcess(command, workingDir = workDir, args = args,
                       options = {poUsePath})
  let c = Conn(p: p, name: (if name != "": name else: command.extractFilename))
  let tpath = getEnv("DVS_PROTOCOL_TRANSCRIPT")
  if tpath != "":
    c.transcript = open(tpath, fmAppend)
    c.hasTranscript = true
  result = Backend()
  result.hello = proc (): Hello =
    helloFromJson(c.call("hello", %*{"protocol": ProtocolVersion}))
  result.stage = proc (use: string; args: JsonNode) =
    discard c.call("stage", %*{"use": use, "with": args}, 120_000)
  result.endStage = proc () = discard c.call("end-stage", nil)
  result.resolveChord = proc (operation: string): Option[string] =
    let j = c.call("resolve-chord", %*{"operation": operation})
    if j{"chord"}.kind == JString: some(j["chord"].getStr) else: none(string)
  result.locate = proc (locator: JsonNode): LocateResult =
    locateFromJson(c.call("locate", %*{"locator": locator}))
  result.read = proc (instance: string; properties: seq[string]): JsonNode =
    c.call("read", %*{"instance": instance, "properties": properties}){"values"}
  result.send = proc (action: JsonNode) =
    discard c.call("send", %*{"action": action}, 120_000)
  result.await = proc (condition, instance: string; timeoutMs: int): bool =
    c.call("await", %*{"condition": condition, "instance": instance, "timeoutMs": timeoutMs},
           timeoutMs + 10_000){"met"}.getBool
  result.record = proc (op: RecordOp; args: JsonNode): JsonNode =
    var a = (if args == nil: newJObject() else: args.copy)
    a["op"] = %($op)
    c.call("record", a, 120_000)
  result.hit = proc (x, y: float): Option[string] =
    let j = c.call("hit", %*{"x": x, "y": y})
    if j{"locator"}.kind == JString: some(j["locator"].getStr) else: none(string)
  result.close = proc () =
    if not c.dead:
      try: discard c.call("shutdown", nil, 5_000)
      except BackendError: discard
    c.dead = true
    if c.p.running:
      sleep(50)
      if c.p.running: c.p.terminate()
    discard c.p.waitForExit(5_000)
    c.p.close()
    if c.hasTranscript: c.transcript.close()

# --- serving ---------------------------------------------------------------------------

proc errorResponse(id: JsonNode; kind: BackendErrorKind; msg: string): JsonNode =
  %*{"id": id, "ok": false, "error": {"kind": $kind, "message": msg}}

proc dispatch*(b: Backend; req: JsonNode): JsonNode =
  let id = req{"id"}
  if id == nil or id.kind != JInt:
    return errorResponse(newJNull(), beProtocol, "a request needs an integer id")
  try:
    var res = newJObject()
    case req{"call"}.getStr
    of "hello":
      res = b.hello().toJson
    of "stage":
      b.stage(req{"use"}.getStr, req{"with"})
    of "end-stage":
      b.endStage()
    of "resolve-chord":
      let r = b.resolveChord(req{"operation"}.getStr)
      res["chord"] = (if r.isSome: %r.get else: newJNull())
    of "locate":
      res = b.locate(req{"locator"}).toJson
    of "read":
      var props: seq[string]
      for p in req{"properties"}.getElems: props.add p.getStr
      res["values"] = b.read(req{"instance"}.getStr, props)
    of "send":
      b.send(req{"action"})
    of "await":
      res["met"] = %b.await(req{"condition"}.getStr, req{"instance"}.getStr,
                            req{"timeoutMs"}.getInt(5000))
    of "record":
      let op = parseEnum[RecordOp](req{"op"}.getStr)
      res = b.record(op, req)
      if res == nil: res = newJObject()
    of "hit":
      let r = b.hit(req{"x"}.getFloat, req{"y"}.getFloat)
      res["locator"] = (if r.isSome: %r.get else: newJNull())
    of "shutdown":
      discard
    else:
      return errorResponse(id, beProtocol, "unknown call '" & req{"call"}.getStr & "'")
    res["id"] = id
    res["ok"] = %true
    res
  except BackendError as e:
    errorResponse(id, e.kind, e.msg)
  except CatchableError as e:
    errorResponse(id, beInternal, e.msg)

proc serveJsonLines*(b: Backend; input = stdin; output = stdout) =
  ## Serves requests until `shutdown` or end of input.
  var line: string
  while input.readLine(line):
    if line.strip.len == 0: continue
    var req: JsonNode
    try: req = parseJson(line)
    except JsonParsingError, ValueError:
      output.writeLine($errorResponse(newJNull(), beProtocol, "not JSON: " & line[0 ..< min(80, line.len)]))
      output.flushFile()
      continue
    let resp = dispatch(b, req)
    output.writeLine($resp)
    output.flushFile()
    if req{"call"}.getStr == "shutdown": break
  if b.close != nil: b.close()
