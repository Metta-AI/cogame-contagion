## Pure game rules for Contagion. No IO, no networking, no LLM — the game
## server, the tests and the wasm replay viewer all drive this same module.
##
## Six regions sit on a 6-cycle plus its three long diagonals (K3,3): nine
## roads, every region with exactly two main roads and one back road. Each
## seat governs one region for `weeks` weeks. Every week each governor sets
## three dials (lockdown, testing, one gate per road), may address the table
## and may wire aid; the week then resolves for all six regions at once.
##
## EVERY rate is an integer in parts per million and every update is integer
## arithmetic with truncating division. That is load-bearing: the wasm replay
## viewer re-runs these same rules in the browser and its re-derivation is
## checked field-for-field against the recorded weeks. With floats that check
## would be a coin flip between native x86 and wasm; with integers it is
## exact.

import std/[json, random, strutils, unicode], types

export types

const
  Pop* = 1_000_000'i64          ## every region starts with this many people
  MinWeeks* = 4
  MaxWeeks* = 40
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 90_000
  MaxSayLen* = 160
  MaxNotesLen* = 700
  RulesVersion* = "contagion.rules.v1"

  RegionNames*: array[Regions, string] = [
    "Harborlea", "Kestrel Flats", "Riverbend",
    "Ash Hollow", "Wintermoor", "Saltmarch"
  ]

  ## The nine roads: the 6-cycle (main) then the three diagonals (back).
  ## Mobility is the share of a region's contacts that ride this road.
  Edges*: array[9, tuple[a, b: int, mobility: int64, main: bool]] = [
    (0, 1, 250_000'i64, true),
    (1, 2, 250_000'i64, true),
    (2, 3, 250_000'i64, true),
    (3, 4, 250_000'i64, true),
    (4, 5, 250_000'i64, true),
    (5, 0, 250_000'i64, true),
    (0, 3, 150_000'i64, false),
    (1, 4, 150_000'i64, false),
    (2, 5, 150_000'i64, false)
  ]

  ## Each region's incident edges in a FIXED total order: the two main roads
  ## (anticlockwise neighbour, then clockwise neighbour), then the back road.
  ## This order is the order of the `gates` array, of the observation's
  ## neighbour list and of a reply's `borders` entries.
  NeighboursOf*: array[Regions, array[Degree, int]] = [
    [5, 0, 6],
    [0, 1, 7],
    [1, 2, 8],
    [2, 3, 6],
    [3, 4, 7],
    [4, 5, 8]
  ]

  ## ---- The public constant tables (printed in every prompt) -------------
  BetaPpm*: array[5, int64] =
    [1_150_000'i64, 900_000, 640_000, 400_000, 220_000]
  TestFactorPpm*: array[4, int64] = [1_000_000'i64, 900_000, 780_000, 640_000]
  DetectPpm*: array[4, int64] = [150_000'i64, 350_000, 650_000, 900_000]
  GatePassPpm*: array[3, int64] = [1_000_000'i64, 400_000, 0]
  LockdownGdpPpm*: array[5, int64] =
    [1_000_000'i64, 920_000, 800_000, 620_000, 400_000]
  TestCost*: array[4, int64] = [0'i64, 20, 55, 110]
  BorderOwnCost*: array[3, int64] = [0'i64, 10, 30]
  BorderNeighbourCost*: array[3, int64] = [0'i64, 5, 15]

  LeakPpm* = 120_000'i64        ## a sealed road still passes 12% of traffic
  CrossBetaPpm* = 700_000'i64
  ForceCapPpm* = 900_000'i64
  ResolvePpm* = 350_000'i64
  BaseIfrPpm* = 8_000'i64
  HospitalCap* = 25_000'i64
  MaxOverloadPpm* = 3_000_000'i64
  BaseGdp* = 1_000'i64
  SickDragMultPpm* = 1_500_000'i64
  SickDragCapPpm* = 600_000'i64
  DeathPenalty* = 2'i64
  MaxAidPerWeek* = 200'i64
  MaxAidEntries* = 3
  SeedInfected* = 40'i64
  OutbreakInfected* = 1_200'i64
  VariantMultPpm* = 1_250_000'i64

type
  Phase* = enum
    phDials = "dials"     ## the observed week is waiting for six decisions
    phDone = "done"

  WeekRecord* = object
    regions*: array[Regions, RegionState]  ## by POSITION
    decisions*: array[Regions, Decision]   ## by POSITION
    decided*: array[Regions, bool]

  Sim* = object
    config*: GameConfig
    names*: seq[string]                ## region alias per SEAT
    posOf*: array[Seats, int]          ## seat -> position
    seatOf*: array[Regions, int]       ## position -> seat
    outbreakPos*: int
    variantWeek*: int
    week*: int                         ## the observed week
    regions*: array[Regions, RegionState]
    pending*: array[Seats, bool]       ## still owes a decision this week
    pendingDecision*: array[Regions, Decision]
    says*: array[Regions, string]      ## this week's talk, by position
    heard*: array[Regions, string]     ## last week's talk, by position
    notes*: seq[string]                ## private notebook per SEAT
    history*: seq[WeekRecord]          ## one record per observed week
    edgeFlow*: array[9, int64]         ## imported cases across each road
    weeksPlayed*: int
    phase*: Phase
    done*: bool
    reason*: string                    ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Graph helpers ----------------------------------------------------------

proc otherEnd*(edge, pos: int): int =
  ## The region at the far end of `edge` from `pos`.
  if Edges[edge].a == pos: Edges[edge].b else: Edges[edge].a

proc slotOf*(pos, edge: int): int =
  ## Which of `pos`'s three incident-edge slots is `edge`; -1 if not incident.
  for slot in 0 ..< Degree:
    if NeighboursOf[pos][slot] == edge:
      return slot
  -1

proc neighbours*(pos: int): seq[int] =
  ## The three neighbouring positions, in the region's fixed slot order.
  for slot in 0 ..< Degree:
    result.add(otherEnd(NeighboursOf[pos][slot], pos))

proc positionOfName*(name: string): int =
  ## Region alias -> position, case-insensitively; -1 when unknown.
  let wanted = name.strip().toLowerAscii()
  for pos in 0 ..< Regions:
    if RegionNames[pos].toLowerAscii() == wanted:
      return pos
  -1

proc roadName*(edge: int): string =
  if Edges[edge].main: "main" else: "back"

proc alive*(region: RegionState): int64 =
  Pop - region.dead

proc hospitalBandName*(band: int): string =
  case band
  of 0: "normal"
  of 1: "strained"
  of 2: "overloaded"
  else: "critical"

proc hospitalBand*(load: int64): int =
  if load < 400_000: 0
  elif load < Ppm: 1
  elif load < 2_000_000: 2
  else: 3

# ---- Setup ------------------------------------------------------------------

proc regionNames*(config: GameConfig): seq[string] =
  ## The six region aliases in POSITION order. Regions are fixed to positions
  ## (the art and the labels are stable); the seat -> position permutation is
  ## what anonymises the table.
  for pos in 0 ..< Regions:
    result.add(RegionNames[pos])

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the week count and the spectator pacing into the episode's limits.
  ## Idempotent: a config that already carries the cap (a replay being
  ## re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.weeks = max(min(config.weeks, MaxWeeks), MinWeeks)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.weeks, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, week: -1, seat: -1, pos: -1,
    decision: blankDecision())

proc variantActive*(sim: Sim): bool =
  sim.week >= sim.variantWeek

proc reportRegion(region: var RegionState) =
  ## Step 7: what the governors are told, rather than what is true.
  region.confirmed = region.infected * DetectPpm[region.testing] div Ppm
  region.confirmedNew =
    region.newInfections * DetectPpm[region.testing] div Ppm

proc logWeek(sim: var Sim) =
  var event = blankEvent(evWeek)
  event.week = sim.week
  event.variant = sim.variantActive()
  for pos in 0 ..< Regions:
    event.regions.add(sim.regions[pos])
  sim.addEvent(event)

proc openWeek(sim: var Sim) =
  ## The observed week becomes live: every seat owes a decision and last
  ## week's talk moves into `heard`, public and one week late.
  for seat in 0 ..< Seats:
    sim.pending[seat] = true
  for pos in 0 ..< Regions:
    sim.pendingDecision[pos] = blankDecision()
  sim.heard = sim.says
  for pos in 0 ..< Regions:
    sim.says[pos] = ""
  var record: WeekRecord
  record.regions = sim.regions
  sim.history.add(record)
  sim.phase = phDials
  sim.logWeek()

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(ContagionError,
      "contagion needs exactly " & $Seats & " players")
  if config.weeks < MinWeeks:
    raise newException(ContagionError,
      "weeks must be at least " & $MinWeeks)
  result = Sim(config: config)
  ## One stream for everything the seed decides, drawn in this order:
  ## the seat -> position permutation, the outbreak position, the variant week.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var positions = @[0, 1, 2, 3, 4, 5]
  rng.shuffle(positions)
  for seat in 0 ..< Seats:
    result.posOf[seat] = positions[seat]
    result.seatOf[positions[seat]] = seat
  result.outbreakPos = rng.rand(Regions - 1)
  result.variantWeek = 8 + rng.rand(4)     # 8..12
  for seat in 0 ..< Seats:
    result.names.add(RegionNames[result.posOf[seat]])
  for pos in 0 ..< Regions:
    let infected =
      if pos == result.outbreakPos: SeedInfected + OutbreakInfected
      else: SeedInfected
    result.regions[pos] = RegionState(
      susceptible: Pop - infected,
      infected: infected,
      recovered: 0,
      dead: 0,
      gdp: 0,
      lockdown: 0,
      testing: 0,
      gates: [0, 0, 0]
    )
    result.regions[pos].hospital =
      hospitalBand(infected * Ppm div HospitalCap)
    reportRegion(result.regions[pos])
    result.regions[pos].confirmedNew = 0
  result.notes = newSeq[string](Seats)
  result.week = 0
  result.addEvent(blankEvent(evStart))
  result.openWeek()

# ---- Queries ----------------------------------------------------------------

proc regionOf*(sim: Sim, seat: int): string =
  RegionNames[sim.posOf[seat]]

proc pendingSeats*(sim: Sim): seq[int] =
  ## The seats whose decision for the observed week is still due, in seat
  ## order. Empty once the episode is over.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if sim.pending[seat]:
      result.add(seat)

proc score*(sim: Sim, seat: int): int64 =
  let region = sim.regions[sim.posOf[seat]]
  region.gdp - DeathPenalty * region.dead

proc effectiveGate*(sim: Sim, edge: int): int =
  ## The tighter of the two ends governs the road.
  let a = Edges[edge].a
  let b = Edges[edge].b
  max(sim.regions[a].gates[slotOf(a, edge)],
      sim.regions[b].gates[slotOf(b, edge)])

proc ifrPpm*(infectedNow: int64): int64 =
  ## The week's infection-fatality rate for a region carrying `infectedNow`
  ## infectious people: 0.8% while the hospitals cope, rising linearly with
  ## the overload to at most 4x that.
  let load = infectedNow * Ppm div HospitalCap
  let over = min(MaxOverloadPpm, max(0'i64, load - Ppm))
  BaseIfrPpm + (BaseIfrPpm * over) div Ppm

proc passPpm*(effGate: int): int64 =
  ## A road's pass-through after its barrier. LeakPpm is the floor for every
  ## road in the game: two ends sealed still pass 12% of their traffic.
  LeakPpm + ((Ppm - LeakPpm) * GatePassPpm[effGate]) div Ppm

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  for seat in 0 ..< Seats:
    sim.pending[seat] = false
  var event = blankEvent(evEnd)
  event.week = sim.weeksPlayed
  event.text = reason
  sim.addEvent(event)

proc resolveWeek(sim: var Sim) =
  ## All six decisions are latched: the week resolves, in the numbered order
  ## of the rules. Steps 1 (dials latch) and 2 (talk queues) already happened
  ## in `applyDecision` / `openWeek`.
  let variantOn = sim.variantActive()
  var i0, s0, a0: array[Regions, int64]
  for pos in 0 ..< Regions:
    i0[pos] = sim.regions[pos].infected
    s0[pos] = sim.regions[pos].susceptible
    a0[pos] = sim.regions[pos].alive

  ## 3. Aid settles. Each sender's clamp read only its own pre-step ledger
  ## when the decision was latched, so the outcome cannot depend on the order
  ## senders are visited; seat order fixes the feed and nothing else.
  var aidIn, aidOut: array[Regions, int64]
  for seat in 0 ..< Seats:
    let pos = sim.posOf[seat]
    for entry in sim.pendingDecision[pos].aid:
      aidOut[pos] += entry.amount
      aidIn[entry.to] += entry.amount
  for pos in 0 ..< Regions:
    sim.regions[pos].gdp += aidIn[pos] - aidOut[pos]
    sim.regions[pos].aidIn = aidIn[pos]
    sim.regions[pos].aidOut = aidOut[pos]

  ## 4. Infection crosses the roads. Every force is computed from the
  ## pre-resolution state of EVERY region first, then applied, so nobody's
  ## spread depends on the order regions are visited.
  var effGate: array[9, int]
  for edge in 0 ..< Edges.len:
    effGate[edge] = sim.effectiveGate(edge)
  var prevalence: array[Regions, int64]
  for pos in 0 ..< Regions:
    prevalence[pos] = if a0[pos] > 0: i0[pos] * Ppm div a0[pos] else: 0
  var newInfections: array[Regions, int64]
  for edge in 0 ..< Edges.len:
    sim.edgeFlow[edge] = 0
  for pos in 0 ..< Regions:
    var beta = BetaPpm[sim.regions[pos].lockdown]
    if variantOn:
      beta = beta * VariantMultPpm div Ppm
    let local =
      ((beta * TestFactorPpm[sim.regions[pos].testing]) div Ppm) *
        prevalence[pos] div Ppm
    var force = local
    for slot in 0 ..< Degree:
      let edge = NeighboursOf[pos][slot]
      let far = otherEnd(edge, pos)
      let imported =
        (((Edges[edge].mobility * passPpm(effGate[edge])) div Ppm) *
          ((CrossBetaPpm * prevalence[far]) div Ppm)) div Ppm
      force += imported
      ## Viewer-only: the people this road carried into `pos` this week.
      sim.edgeFlow[edge] += s0[pos] * imported div Ppm
    force = min(ForceCapPpm, force)
    newInfections[pos] = min(s0[pos], (s0[pos] * force) div Ppm)
  for pos in 0 ..< Regions:
    sim.regions[pos].susceptible = s0[pos] - newInfections[pos]
    sim.regions[pos].infected = i0[pos] + newInfections[pos]
    sim.regions[pos].newInfections = newInfections[pos]

  ## 5. Economy and GDP, on this week's sickness and last week's workforce.
  for pos in 0 ..< Regions:
    let aliveShare = a0[pos] * Ppm div Pop
    let sickPrev =
      if a0[pos] > 0: sim.regions[pos].infected * Ppm div a0[pos] else: 0
    let sick = min(SickDragCapPpm, (sickPrev * SickDragMultPpm) div Ppm)
    let outputPpm =
      (((LockdownGdpPpm[sim.regions[pos].lockdown] * aliveShare) div Ppm) *
        (Ppm - sick)) div Ppm
    var spend = TestCost[sim.regions[pos].testing]
    for slot in 0 ..< Degree:
      let edge = NeighboursOf[pos][slot]
      let far = otherEnd(edge, pos)
      spend += BorderOwnCost[sim.regions[pos].gates[slot]]
      ## The spillover: a road your neighbour shut costs you trade too.
      spend += BorderNeighbourCost[sim.regions[far].gates[slotOf(far, edge)]]
    sim.regions[pos].grossGdp = BaseGdp * outputPpm div Ppm
    sim.regions[pos].spendWeek = spend
    sim.regions[pos].gdp += sim.regions[pos].grossGdp - spend

  ## 6. Deaths and recoveries: only the cohort that was already infectious.
  for pos in 0 ..< Regions:
    let load = sim.regions[pos].infected * Ppm div HospitalCap
    let ifr = ifrPpm(sim.regions[pos].infected)
    let resolved = i0[pos] * ResolvePpm div Ppm
    let deaths = resolved * ifr div Ppm
    sim.regions[pos].infected -= resolved
    sim.regions[pos].recovered += resolved - deaths
    sim.regions[pos].dead += deaths
    sim.regions[pos].deathsWeek = deaths
    sim.regions[pos].hospital = hospitalBand(load)
    ## 7. Report.
    reportRegion(sim.regions[pos])

  ## 8. Log and advance.
  inc sim.weeksPlayed
  inc sim.week
  if sim.weeksPlayed >= sim.config.weeks:
    ## The final week is observed (its state is logged and its costs count)
    ## but takes no decisions.
    var record: WeekRecord
    record.regions = sim.regions
    sim.history.add(record)
    sim.heard = sim.says
    for pos in 0 ..< Regions:
      sim.says[pos] = ""
    sim.logWeek()
    sim.settle("complete")
  else:
    sim.openWeek()

proc applyDecision*(sim: var Sim, seat: int, decision: Decision,
    scripted: bool) =
  ## `seat` submits its dials for the observed week. Raises ContagionError on
  ## a HARD-INVALID decision; the server falls back to the scripted sentinel
  ## move on a rejection. Soft corrections (an unknown road, an out-of-range
  ## gate, unaffordable aid) are applied here and marked on the event.
  ##
  ## This is the only mutation path, and the apply ORDER across seats cannot
  ## change the outcome: it only latches. The sixth call resolves the week.
  if sim.done:
    raise newException(ContagionError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(ContagionError, "bad seat: " & $seat)
  if not sim.pending[seat]:
    raise newException(ContagionError,
      sim.names[seat] & " has already decided this week")
  if decision.lockdown < 0 or decision.lockdown > 4:
    raise newException(ContagionError,
      "lockdown must be 0..4: " & $decision.lockdown)
  if decision.testing < 0 or decision.testing > 3:
    raise newException(ContagionError,
      "testing must be 0..3: " & $decision.testing)
  let pos = sim.posOf[seat]
  var latched = decision

  ## 1. Dials latch. A gate the governor did not mention (-1) keeps last
  ## week's value.
  for slot in 0 ..< Degree:
    let wanted = decision.borders[slot]
    if wanted < -1 or wanted > 2:
      raise newException(ContagionError, "gate must be 0..2: " & $wanted)
    if wanted >= 0:
      sim.regions[pos].gates[slot] = wanted
    latched.borders[slot] = sim.regions[pos].gates[slot]
  sim.regions[pos].lockdown = decision.lockdown
  sim.regions[pos].testing = decision.testing

  ## Aid is validated and clamped against this region's ledger as it stands
  ## at the start of the week — which is also how it stands at the start of
  ## the settle step, since nothing between the two touches a ledger.
  let budget = max(0'i64, min(MaxAidPerWeek, sim.regions[pos].gdp))
  var sent = 0'i64
  var kept: seq[AidEntry]
  for entry in decision.aid:
    if kept.len >= MaxAidEntries:
      latched.corrected = true
      break
    if entry.to < 0 or entry.to >= Regions or entry.to == pos:
      latched.corrected = true
      continue
    if entry.amount < 0:
      latched.corrected = true
      continue
    if entry.amount == 0:
      continue
    var amount = entry.amount
    if sent + amount > budget:
      amount = budget - sent
      latched.corrected = true
    if amount <= 0:
      continue
    kept.add(AidEntry(to: entry.to, amount: amount))
    sent += amount
  latched.aid = kept

  ## Talk. Cut on a RUNE boundary: a byte slice through a multi-byte
  ## character would leave invalid UTF-8 in the replay and break its JSON.
  var message = decision.say.strip().replace("\n", " ").replace("\r", " ")
  if not sim.config.talk:
    message = ""
  if message.runeLen > MaxSayLen:
    message = message.runeSubStr(0, MaxSayLen - 1) & "…"
  latched.say = message
  sim.says[pos] = message

  if decision.notes.len > 0:
    var notes = decision.notes
    if notes.runeLen > MaxNotesLen:
      notes = notes.runeSubStr(0, MaxNotesLen - 1) & "…"
    sim.notes[seat] = notes
  latched.notes = sim.notes[seat]

  sim.pending[seat] = false
  sim.pendingDecision[pos] = latched
  sim.history[^1].decisions[pos] = latched
  sim.history[^1].decided[pos] = true

  var event = blankEvent(evDial)
  event.week = sim.week
  event.seat = seat
  event.pos = pos
  event.decision = latched
  event.scripted = scripted
  event.text = sim.notes[seat]
  sim.addEvent(event)

  if sim.pendingSeats().len == 0:
    sim.resolveWeek()

proc endEarly*(sim: var Sim) =
  ## Stop now, BETWEEN weeks. The hosted platform kills an episode that
  ## outlives its timeout and keeps nothing at all, so a short honest episode
  ## always beats a long one that never lands. Scores use the weeks played.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Aid ledger -------------------------------------------------------------

type
  Transfer* = object
    fromPos*: int
    toPos*: int
    amount*: int64

proc transfersOfWeek*(sim: Sim, week: int): seq[Transfer] =
  ## Every aid transfer settled in the resolution of observed week `week`.
  if week < 0 or week >= sim.history.len:
    return
  let record = sim.history[week]
  for pos in 0 ..< Regions:
    if not record.decided[pos]:
      continue
    for entry in record.decisions[pos].aid:
      result.add(Transfer(fromPos: pos, toPos: entry.to, amount: entry.amount))

proc aidTotals*(sim: Sim): tuple[sent, received: array[Regions, int64]] =
  for week in 0 ..< sim.weeksPlayed:
    for transfer in sim.transfersOfWeek(week):
      result.sent[transfer.fromPos] += transfer.amount
      result.received[transfer.toPos] += transfer.amount

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var gdps = newJArray()
  var deaths = newJArray()
  var regions = newJArray()
  var totalDeaths = 0'i64
  var totalGdp = 0'i64
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes by POLICY name, not
    ## by the region alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    let region = sim.regions[sim.posOf[seat]]
    gdps.add(%region.gdp)
    deaths.add(%region.dead)
    regions.add(%RegionNames[sim.posOf[seat]])
    totalDeaths += region.dead
    totalGdp += region.gdp
  %*{
    "names": names,
    "scores": scores,
    "gdp": gdps,
    "deaths": deaths,
    "regions": regions,
    "weeks": sim.weeksPlayed,
    "maxWeeks": sim.config.weeks,
    "totalDeaths": totalDeaths,
    "totalGdp": totalGdp,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Region JSON ------------------------------------------------------------

proc regionJson*(region: RegionState): JsonNode =
  %*{
    "susceptible": region.susceptible,
    "infected": region.infected,
    "recovered": region.recovered,
    "dead": region.dead,
    "gdp": region.gdp,
    "lockdown": region.lockdown,
    "testing": region.testing,
    "gates": [region.gates[0], region.gates[1], region.gates[2]],
    "newInfections": region.newInfections,
    "deathsWeek": region.deathsWeek,
    "confirmed": region.confirmed,
    "confirmedNew": region.confirmedNew,
    "grossGdp": region.grossGdp,
    "spendWeek": region.spendWeek,
    "aidIn": region.aidIn,
    "aidOut": region.aidOut,
    "hospital": region.hospital
  }

proc regionFromJson*(node: JsonNode): RegionState =
  result = RegionState(
    susceptible: node{"susceptible"}.getBiggestInt(),
    infected: node{"infected"}.getBiggestInt(),
    recovered: node{"recovered"}.getBiggestInt(),
    dead: node{"dead"}.getBiggestInt(),
    gdp: node{"gdp"}.getBiggestInt(),
    lockdown: node{"lockdown"}.getInt(),
    testing: node{"testing"}.getInt(),
    newInfections: node{"newInfections"}.getBiggestInt(),
    deathsWeek: node{"deathsWeek"}.getBiggestInt(),
    confirmed: node{"confirmed"}.getBiggestInt(),
    confirmedNew: node{"confirmedNew"}.getBiggestInt(),
    grossGdp: node{"grossGdp"}.getBiggestInt(),
    spendWeek: node{"spendWeek"}.getBiggestInt(),
    aidIn: node{"aidIn"}.getBiggestInt(),
    aidOut: node{"aidOut"}.getBiggestInt(),
    hospital: node{"hospital"}.getInt()
  )
  if node.hasKey("gates") and node["gates"].len == Degree:
    for slot in 0 ..< Degree:
      result.gates[slot] = node["gates"][slot].getInt()

# ---- Viewer state -----------------------------------------------------------

proc gatesJson(sim: Sim, pos: int): JsonNode =
  result = newJArray()
  for slot in 0 ..< Degree:
    let edge = NeighboursOf[pos][slot]
    let far = otherEnd(edge, pos)
    result.add(%*{
      "to": RegionNames[far],
      "pos": far,
      "gate": sim.regions[pos].gates[slot],
      "eff": sim.effectiveGate(edge),
      "road": roadName(edge)
    })

proc aidJson(entries: seq[AidEntry]): JsonNode =
  result = newJArray()
  for entry in entries:
    result.add(%*{"to": RegionNames[entry.to], "amount": entry.amount})

proc tableStateJson*(sim: Sim): JsonNode =
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let pos = sim.posOf[seat]
    let region = sim.regions[pos]
    var heard = newJArray()
    for other in 0 ..< Regions:
      if sim.heard[other].len > 0:
        heard.add(%*{"region": RegionNames[other], "say": sim.heard[other]})
    seats.add(%*{
      "seat": seat,
      "pos": pos,
      "region": RegionNames[pos],
      "name": RegionNames[pos],
      "score": sim.score(seat),
      "gdp": region.gdp,
      "deaths": region.dead,
      "deathsWeek": region.deathsWeek,
      "infected": region.infected,
      "confirmed": region.confirmed,
      "confirmedNew": region.confirmedNew,
      "newInfections": region.newInfections,
      "susceptible": region.susceptible,
      "recovered": region.recovered,
      "alive": region.alive,
      "lockdown": region.lockdown,
      "testing": region.testing,
      "hospital": region.hospital,
      "gates": gatesJson(sim, pos),
      "grossGdp": region.grossGdp,
      "spendWeek": region.spendWeek,
      "aidIn": region.aidIn,
      "aidOut": region.aidOut,
      "aid": aidJson(sim.pendingDecision[pos].aid),
      "say": sim.says[pos],
      "heard": heard,
      "notes": sim.notes[seat],
      "pending": sim.pending[seat]
    })
  var posSeat = newJArray()
  for pos in 0 ..< Regions:
    posSeat.add(%sim.seatOf[pos])
  var regionsNode = newJArray()
  for pos in 0 ..< Regions:
    regionsNode.add(%RegionNames[pos])
  var edges = newJArray()
  for edge in 0 ..< Edges.len:
    edges.add(%*{
      "a": Edges[edge].a,
      "b": Edges[edge].b,
      "road": roadName(edge),
      "eff": sim.effectiveGate(edge),
      "flow": sim.edgeFlow[edge]
    })
  ## Curves are revealed only up to the current week, never ahead.
  var infectedCurve = newJArray()
  var deathsCurve = newJArray()
  var gdpCurve = newJArray()
  var confirmedCurve = newJArray()
  for pos in 0 ..< Regions:
    var infectedSeries = newJArray()
    var deathsSeries = newJArray()
    var gdpSeries = newJArray()
    var confirmedSeries = newJArray()
    for record in sim.history:
      infectedSeries.add(%record.regions[pos].infected)
      deathsSeries.add(%record.regions[pos].dead)
      gdpSeries.add(%record.regions[pos].gdp)
      confirmedSeries.add(%record.regions[pos].confirmed)
    infectedCurve.add(infectedSeries)
    deathsCurve.add(deathsSeries)
    gdpCurve.add(gdpSeries)
    confirmedCurve.add(confirmedSeries)
  %*{
    "seats": seats,
    "posSeat": posSeat,
    "regions": regionsNode,
    "edges": edges,
    "week": sim.week,
    "weeks": sim.config.weeks,
    "weeksPlayed": sim.weeksPlayed,
    "variant": sim.variantActive(),
    "curves": {
      "infected": infectedCurve,
      "deaths": deathsCurve,
      "gdp": gdpCurve,
      "confirmed": confirmedCurve
    },
    "hospitalCap": HospitalCap,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- The per-seat observation -----------------------------------------------

proc historyRowsJson(sim: Sim, pos: int): JsonNode =
  result = newJArray()
  for week, record in sim.history:
    let region = record.regions[pos]
    result.add(%*{
      "week": week,
      "confirmed": region.confirmed,
      "confirmedNew": region.confirmedNew,
      "deathsWeek": region.deathsWeek,
      "lockdown": region.lockdown,
      "testing": region.testing,
      "gates": [region.gates[0], region.gates[1], region.gates[2]],
      "grossGdp": region.grossGdp,
      "spendWeek": region.spendWeek,
      "net": region.grossGdp - region.spendWeek,
      "gdp": region.gdp
    })

proc playerViewJson*(sim: Sim, seat: int): JsonNode =
  ## What a governor may see. The TRUE infected / susceptible / recovered of
  ## every region (including its own) are absent; a governor only ever sees
  ## `confirmed`, which at testing 0 is 15% of the truth. Other regions'
  ## hospital bands and private notes are absent too. The prompt the server
  ## builds for this seat carries exactly this information and no more.
  let pos = sim.posOf[seat]
  let mine = sim.regions[pos]
  var spendOwnBorders = 0'i64
  var spendNeighbourBorders = 0'i64
  for slot in 0 ..< Degree:
    let edge = NeighboursOf[pos][slot]
    let far = otherEnd(edge, pos)
    spendOwnBorders += BorderOwnCost[mine.gates[slot]]
    spendNeighbourBorders +=
      BorderNeighbourCost[sim.regions[far].gates[slotOf(far, edge)]]
  var others = newJArray()
  for other in 0 ..< Regions:
    if other == pos:
      continue
    var gates = newJArray()
    for slot in 0 ..< Degree:
      let edge = NeighboursOf[other][slot]
      gates.add(%*{
        "to": RegionNames[otherEnd(edge, other)],
        "gate": sim.regions[other].gates[slot],
        "road": roadName(edge)
      })
    others.add(%*{
      "region": RegionNames[other],
      "pos": other,
      "confirmed": sim.regions[other].confirmed,
      "confirmedNew": sim.regions[other].confirmedNew,
      "deaths": sim.regions[other].dead,
      "gdp": sim.regions[other].gdp,
      "score": sim.score(sim.seatOf[other]),
      "lockdown": sim.regions[other].lockdown,
      "testing": sim.regions[other].testing,
      "gates": gates
    })
  var heard = newJArray()
  if sim.config.talk:
    for other in 0 ..< Regions:
      if sim.heard[other].len > 0:
        heard.add(%*{"region": RegionNames[other], "say": sim.heard[other]})
  let totals = sim.aidTotals()
  var lastTransfers = newJArray()
  for transfer in sim.transfersOfWeek(sim.weeksPlayed - 1):
    lastTransfers.add(%*{
      "from": RegionNames[transfer.fromPos],
      "to": RegionNames[transfer.toPos],
      "amount": transfer.amount
    })
  var aidTotalsNode = newJArray()
  for other in 0 ..< Regions:
    aidTotalsNode.add(%*{
      "region": RegionNames[other],
      "sent": totals.sent[other],
      "received": totals.received[other]
    })
  var mapEdges = newJArray()
  for edge in 0 ..< Edges.len:
    mapEdges.add(%*{
      "a": RegionNames[Edges[edge].a],
      "b": RegionNames[Edges[edge].b],
      "road": roadName(edge)
    })
  %*{
    "week": sim.week,
    "weeks": sim.config.weeks,
    "weeksPlayed": sim.weeksPlayed,
    "variant": sim.variantActive(),
    "region": RegionNames[pos],
    "pos": pos,
    "regions": regionNames(sim.config),
    "map": mapEdges,
    "own": {
      "confirmed": mine.confirmed,
      "confirmedNew": mine.confirmedNew,
      "deaths": mine.dead,
      "deathsWeek": mine.deathsWeek,
      "gdp": mine.gdp,
      "grossGdp": mine.grossGdp,
      "spendWeek": mine.spendWeek,
      "spendTesting": TestCost[mine.testing],
      "spendOwnBorders": spendOwnBorders,
      "spendNeighbourBorders": spendNeighbourBorders,
      "aidIn": mine.aidIn,
      "aidOut": mine.aidOut,
      "lockdown": mine.lockdown,
      "testing": mine.testing,
      "gates": gatesJson(sim, pos),
      "hospital": hospitalBandName(mine.hospital),
      "score": sim.score(seat)
    },
    "others": others,
    "aidLastWeek": lastTransfers,
    "aidTotals": aidTotalsNode,
    "heard": heard,
    "notes": sim.notes[seat],
    "history": historyRowsJson(sim, pos),
    "phase": $sim.phase,
    "done": sim.done,
    "reason": sim.reason
  }

# ---- Replay -----------------------------------------------------------------

proc sameRegions(a: seq[RegionState], b: seq[RegionState]): bool =
  if a.len != b.len:
    return false
  for index in 0 ..< a.len:
    if a[index] != b[index]:
      return false
  true

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the whole timeline from a recorded event log: `initSim`
  ## re-draws the permutation, the outbreak position and the variant week
  ## from the seed, each `dial` event is replayed through `applyDecision`,
  ## and each `week` event is CHECKED field-for-field against the
  ## re-derivation. All integers, so the check is exact.
  ## frames[i] = state after events[0..<i].
  var sim = initSim(config)
  ## initSim already logged the start and the first week event; the recorded
  ## log opens with those same two.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evWeek:
      if event.week != sim.week or event.variant != sim.variantActive() or
          not sameRegions(event.regions, @(sim.regions)):
        raise newException(ContagionError,
          "week " & $event.week & " does not match the seeded re-derivation")
      if sim.events.len == 0 or sim.events[^1].kind != evWeek:
        sim.events.add(event)
    of evDial:
      sim.applyDecision(event.seat, event.decision, event.scripted)
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the dials alone.
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.week >= 0:
    result["week"] = %event.week
  case event.kind
  of evStart:
    discard
  of evWeek:
    result["variant"] = %event.variant
    var regions = newJArray()
    for region in event.regions:
      regions.add(regionJson(region))
    result["regions"] = regions
  of evDial:
    let pos = event.pos
    result["seat"] = %event.seat
    result["pos"] = %pos
    result["region"] = %RegionNames[pos]
    result["lockdown"] = %event.decision.lockdown
    result["testing"] = %event.decision.testing
    var borders = newJArray()
    for slot in 0 ..< Degree:
      borders.add(%*{
        "to": RegionNames[otherEnd(NeighboursOf[pos][slot], pos)],
        "gate": event.decision.borders[slot]
      })
    result["borders"] = borders
    result["aid"] = aidJson(event.decision.aid)
    if event.decision.say.len > 0:
      result["say"] = %event.decision.say
    result["scripted"] = %event.scripted
    result["corrected"] = %event.decision.corrected
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    week: node{"week"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    pos: node{"pos"}.getInt(-1),
    variant: node{"variant"}.getBool(false),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    decision: blankDecision()
  )
  if node.hasKey("regions"):
    for region in node["regions"]:
      result.regions.add(regionFromJson(region))
  if result.kind == evDial:
    let pos = result.pos
    result.decision.lockdown = node{"lockdown"}.getInt()
    result.decision.testing = node{"testing"}.getInt()
    result.decision.say = node{"say"}.getStr("")
    result.decision.notes = result.text
    result.decision.corrected = node{"corrected"}.getBool(false)
    if node.hasKey("borders") and pos >= 0:
      for entry in node["borders"]:
        let far = positionOfName(entry{"to"}.getStr())
        if far < 0:
          continue
        for slot in 0 ..< Degree:
          if otherEnd(NeighboursOf[pos][slot], pos) == far:
            result.decision.borders[slot] = entry{"gate"}.getInt()
    if node.hasKey("aid"):
      for entry in node["aid"]:
        let far = positionOfName(entry{"to"}.getStr())
        if far < 0:
          continue
        result.decision.aid.add(
          AidEntry(to: far, amount: entry{"amount"}.getBiggestInt()))
