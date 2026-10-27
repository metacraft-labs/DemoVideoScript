## The typed model of a scenario and of a pack's backend-neutral part.

import std/[json, tables]
import ./grammar, ./yaml

export grammar

type
  Severity* = enum
    sevError = "error", sevWarning = "warning"

  Phase* = enum
    ## `phStructural` diagnostics are exactly the ones the published JSON Schema
    ## also rejects; `phSemantic` ones need the pack or the whole scenario.
    phStructural, phSemantic

  Diagnostic* = object
    rule*: string        ## "yaml", "schema", "version", "L1" … "L12", "pack"
    severity*: Severity
    phase*: Phase
    file*: string
    line*, col*: int
    message*: string

  Diagnostics* = seq[Diagnostic]

  Millis* = int64

  PaceKind* = enum
    paceNone, pacePreset, paceParams

  Pace* = object
    kind*: PaceKind
    preset*: string                  ## pacePreset, or the base of paceParams
    params*: OrderedTable[string, JsonNode]

  Target* = object
    at*: Locator
    atText*: string                  ## as written, for messages
    anchor*: Invocation              ## name "" when absent (the implicit `center`)
    line*, col*: int

  MatcherKind* = enum
    mEquals = "equals", mContains = "contains", mMatches = "matches", mOneOf = "one-of",
    mLt = "lt", mLe = "le", mGt = "gt", mGe = "ge", mCount = "count",
    mSubsequence = "subsequence", mUnordered = "unordered"

  Matcher* = ref object
    kind*: MatcherKind
    value*: JsonNode                 ## the operand; for mCount see `inner`
    inner*: Matcher

  Relation* = enum
    relAbove = "above", relBelow = "below", relLeftOf = "left-of", relRightOf = "right-of",
    relInside = "inside", relOverlaps = "overlaps", relAlignedLeft = "aligned-left",
    relAlignedTop = "aligned-top", relSpansWidthOf = "spans-width-of",
    relSpansHeightOf = "spans-height-of"

  GeometryCheck* = object
    relations*: seq[tuple[rel: Relation, other: Locator, otherText: string]]
    visible*: int                    ## -1 unspecified, 0 false, 1 true

  Observation* = object
    target*: Target                  ## `at` (anchor unused)
    properties*: OrderedTable[string, Matcher]
    asserts*: seq[Invocation]
    geometry*: GeometryCheck
    hasGeometry*: bool
    role*: string                    ## expected role of the located instance
    absent*: int                     ## -1 unspecified, 0 false, 1 true
    present*: int

  SpanKind* = enum
    spanNarration = "narration", spanCaption = "caption"

  Span* = object
    text*: string
    fromId*, toId*: string           ## "" = this step / beat
    voice*, style*: string
    line*, col*: int

  Callout* = object
    target*: Target
    text*: string
    fromId*, toId*: string
    line*, col*: int

  StepKind* = enum
    stKey = "key", stChord = "chord", stType = "type", stPress = "press",
    stRelease = "release", stMove = "move", stHover = "hover", stClick = "click",
    stDrag = "drag", stWheel = "wheel", stExpect = "expect", stWait = "wait",
    stFlow = "flow", stBeat = "beat", stCapture = "capture", stExt = "ext"

  Button* = enum
    btnLeft = "left", btnRight = "right", btnMiddle = "middle"

  Direction* = enum
    dirUp = "up", dirDown = "down", dirLeft = "left", dirRight = "right"

  Step* = ref object
    kind*: StepKind
    line*, col*: int
    # annotations
    id*: string
    leadIn*, dwell*: Millis          ## -1 when absent
    settle*: bool                    ## input actions: wait for `settled` after
    chapter*: string
    narration*, caption*: Span
    hasNarration*, hasCaption*: bool
    callouts*: seq[Callout]
    alternatives*: OrderedTable[string, seq[Step]]
    # payload, by kind
    key*: string                     ## stKey, stPress/stRelease of a key
    chords*: seq[Chord]              ## stChord (literal)
    bound*: string                   ## stChord by binding
    text*: string                    ## stType
    target*: Target                  ## pointer actions; stPress/stRelease of a button
    isButton*: bool                  ## stPress/stRelease: a pointer button
    button*: Button
    count*: int                      ## stClick
    modifiers*: set[Modifier]
    pace*: Pace
    hoverFor*: Millis                ## stHover, -1 when absent
    dragFrom*, dragTo*: Target
    via*: seq[Target]
    direction*: Direction
    amount*: int
    observation*: Observation        ## stExpect, and stWait with an observation
    untilName*: string               ## stWait on a named condition
    untilIsObservation*: bool
    timeout*: Millis                 ## stWait, -1 when absent
    name*: string                    ## stFlow, stBeat, stCapture, stExt
    args*: YNode                     ## stFlow / stExt `with`
    steps*: seq[Step]                ## stBeat
    captureOf*: Target
    hasCaptureOf*: bool

  StageCall* = object
    use*: string
    args*: YNode
    line*, col*: int

  Scenario* = object
    file*: string
    version*: int
    name*: string
    pack*: string
    summary*: string
    requires*: seq[string]
    stage*: seq[StageCall]
    steps*: seq[Step]

  # --- packs ---------------------------------------------------------------------

  PropKind* = enum
    ptText = "text", ptLines = "lines", ptBool = "bool", ptInt = "int", ptNumber = "number",
    ptRecord = "record", ptListRecord = "list<record>", ptEnum = "enum"

  PropType* = object
    kind*: PropKind
    values*: seq[string]             ## ptEnum

  Multiplicity* = enum
    mulOne = "one", mulOptional = "optional", mulMany = "many"

  Affordance* = enum
    affClick = "click", affDoubleClick = "double-click", affContextClick = "context-click",
    affDragSource = "drag-source", affDropTarget = "drop-target", affWheel = "wheel",
    affTextEntry = "text-entry", affFocusable = "focusable"

  PredKind* = enum
    pdOr, pdAnd, pdNot, pdQuant, pdCmp, pdLit, pdPath, pdCount

  QuantKind* = enum
    qEvery = "every", qSome = "some", qNone = "none"

  PathPart* = object
    name*: string
    dynamic*: bool                   ## x[param]

  Pred* = ref object
    pos*: int                        ## character offset in the predicate text
    case kind*: PredKind
    of pdOr, pdAnd: terms*: seq[Pred]
    of pdNot: operand*: Pred
    of pdQuant:
      quant*: QuantKind
      binder*, binder2*: string      ## binder2 for adjacent pairs
      adjacent*: bool
      ofRole*: string
      body*: Pred
    of pdCmp:
      op*: string
      lhs*, rhs*: Pred
    of pdLit: lit*: JsonNode
    of pdPath: parts*: seq[PathPart]
    of pdCount: countRole*: string

  AssertionDecl* = object
    sig*: Signature
    text*: string
    pred*: Pred                      ## nil when it did not parse
    line*, col*: int

  SyncDecl* = object
    name*: string
    text*: string                    ## "" when binding-detected
    pred*: Pred
    line*, col*: int

  Role* = ref object
    name*: string
    keys*: seq[string]
    properties*: OrderedTable[string, PropType]
    children*: OrderedTable[string, Multiplicity]
    affordances*: set[Affordance]
    anchors*: seq[Signature]
    assertions*: OrderedTable[string, AssertionDecl]
    sync*: OrderedTable[string, SyncDecl]
    line*, col*: int

  FlowDecl* = object
    sig*: Signature
    body*: YNode                     ## raw steps; parsed after substitution
    line*, col*: int

  StageDecl* = object
    name*: string
    params*: OrderedTable[string, PropType]
    line*, col*: int

  Pack* = ref object
    file*: string
    name*: string
    summary*: string
    root*: string
    roles*: OrderedTable[string, Role]
    sync*: OrderedTable[string, SyncDecl]
    flows*: OrderedTable[string, FlowDecl]
    stages*: OrderedTable[string, StageDecl]

const
  InputKinds* = {stKey, stChord, stType, stPress, stRelease, stMove, stHover, stClick,
                 stDrag, stWheel}
  PointerTargetKinds* = {stMove, stHover, stClick, stWheel}
  ImplicitProperties* = ["geometry", "present"]

proc hasErrors*(ds: Diagnostics): bool =
  for d in ds:
    if d.severity == sevError: return true
  false

proc hasStructuralErrors*(ds: Diagnostics): bool =
  for d in ds:
    if d.severity == sevError and d.phase == phStructural: return true
  false

proc `$`*(d: Diagnostic): string =
  d.file & ":" & $d.line & ":" & $d.col & ": " & $d.severity & "[" & d.rule & "]: " & d.message
