## The backend protocol (§6.2), as a Nim interface.
##
## A backend answers a few narrow calls; everything else — flow expansion, the
## capability check, the stage boundary, sequencing, synchronisation, matching,
## named assertions, pacing, timeouts, results and the recording manifest — is
## the runner's. The same calls travel over JSON lines for out-of-process
## backends (`jsonlines.nim`), with the messages of
## `schemas/v1/backend-protocol.schema.json`.
##
## Values cross the interface as JSON, so a binding in any language produces
## exactly what the runner evaluates.

import std/[json, options]

const ProtocolVersion* = 1

type
  BackendErrorKind* = enum
    beUnsupported = "unsupported"    ## the backend cannot perform this at all
    beRefused = "refused"            ## it cannot deliver this input (e.g. a key)
    beNotFound = "not-found"         ## an instance id is no longer valid
    beStageClosed = "stage-closed"   ## a stage call after end-stage
    beStage = "stage"                ## a stage procedure failed
    beProtocol = "protocol"          ## a malformed request or response
    beCrashed = "crashed"            ## the backend process died or did not answer
    beInternal = "internal"

  BackendError* = object of CatchableError
    kind*: BackendErrorKind

  LocateOutcome* = enum
    loOne = "one", loNone = "none", loAmbiguous = "ambiguous"

  LocateResult* = object
    outcome*: LocateOutcome
    instance*: string           ## loOne: an opaque id, valid until the next `send`
    role*: string               ## loOne: the role of the instance
    candidates*: seq[string]    ## loNone / loAmbiguous: what the backend did see

  RecordOp* = enum
    recStart = "start", recMark = "mark", recStill = "still", recStop = "stop"

  BindingDecl* = object
    ## What a binding can deliver for one role on this backend (§4.9).
    affordances*: seq[string]
    properties*: seq[string]

  Hello* = object
    backend*: string
    version*: string
    platform*: string           ## linux, macos, windows
    capabilities*: seq[string]
    bindings*: JsonNode         ## role -> { affordances, properties }; null when undeclared
    units*: string              ## "cell" or "px": the unit of geometry and paths

  Backend* = ref object
    ## One backend session. Every proc may raise `BackendError`.
    hello*: proc (): Hello {.closure.}
    stage*: proc (use: string; args: JsonNode) {.closure.}
    endStage*: proc () {.closure.}
    resolveChord*: proc (operation: string): Option[string] {.closure.}
    locate*: proc (locator: JsonNode): LocateResult {.closure.}
      ## `locator` is the parsed form: a list of segments
      ## ({role, keys, ordinal} | {focused: true} | {ancestor: role}).
    read*: proc (instance: string; properties: seq[string]): JsonNode {.closure.}
      ## { property: value }. "geometry" is { x, y, w, h, visible }.
    send*: proc (action: JsonNode) {.closure.}
      ## A normalised input step with its targets resolved to instance ids
      ## ("target", "from", "to", "via") and, in realistic runs, "timing".
    await*: proc (condition: string; instance: string; timeoutMs: int): bool {.closure.}
      ## A named sync condition (`settled`, a pack condition, or a role's
      ## condition on `instance`). False when the deadline passed.
    record*: proc (op: RecordOp; args: JsonNode): JsonNode {.closure.}
    hit*: proc (x, y: float): Option[string] {.closure.}
      ## The deepest role instance at a point, as a locator (tooling only).
    close*: proc () {.closure.}
    log*: proc (): string {.closure.}
      ## What the backend wrote about itself (an out-of-process backend's
      ## stderr), for a failed run's `failure/backend.log`; nil when it keeps
      ## no log.

proc backendError*(kind: BackendErrorKind; msg: string): ref BackendError =
  result = newException(BackendError, msg)
  result.kind = kind

proc toJson*(h: Hello): JsonNode =
  %*{"backend": h.backend, "version": h.version, "platform": h.platform,
     "capabilities": h.capabilities,
     "bindings": (if h.bindings == nil: newJNull() else: h.bindings), "units": h.units}

proc helloFromJson*(j: JsonNode): Hello =
  result.backend = j{"backend"}.getStr
  result.version = j{"version"}.getStr
  result.platform = j{"platform"}.getStr("linux")
  for c in j{"capabilities"}.getElems: result.capabilities.add c.getStr
  result.bindings = (if j.hasKey("bindings"): j["bindings"] else: newJNull())
  result.units = j{"units"}.getStr("px")

proc toJson*(r: LocateResult): JsonNode =
  result = %*{"outcome": $r.outcome}
  if r.outcome == loOne:
    result["instance"] = %r.instance
    result["role"] = %r.role
  if r.candidates.len > 0: result["candidates"] = %r.candidates

proc locateFromJson*(j: JsonNode): LocateResult =
  case j{"outcome"}.getStr
  of "one": result.outcome = loOne
  of "none": result.outcome = loNone
  of "ambiguous": result.outcome = loAmbiguous
  else: raise backendError(beProtocol, "locate: unknown outcome " & $j{"outcome"})
  result.instance = j{"instance"}.getStr
  result.role = j{"role"}.getStr
  for c in j{"candidates"}.getElems: result.candidates.add c.getStr
