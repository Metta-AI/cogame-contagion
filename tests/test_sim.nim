## Unit tests for the Contagion rules: the graph, the seeded setup, the eight
## numbered resolution steps on a hand-computed week, the leak, the effective
## gate, the spillover, aid clamping, hospital overload, scoring, simultaneity,
## the two endings, determinism and the replay re-derivation.
##
## Every rule is integer parts-per-million arithmetic, so every expectation
## here is an exact equality rather than a tolerance — which is also why the
## wasm viewer's re-derivation of a replay is bit-identical to the server's.

import std/[algorithm, json, sets, strutils, unicode, unittest]
import support/helpers

suite "the graph":
  test "nine roads, every region two main and one back":
    check Edges.len == 9
    var mains = 0
    for edge in 0 ..< Edges.len:
      if Edges[edge].main: inc mains
    check mains == 6
    for pos in 0 ..< Regions:
      var main = 0
      var back = 0
      var seen = initHashSet[int]()
      for slot in 0 ..< Degree:
        let edge = NeighboursOf[pos][slot]
        check edge in 0 ..< Edges.len
        check Edges[edge].a == pos or Edges[edge].b == pos
        if Edges[edge].main: inc main else: inc back
        seen.incl(otherEnd(edge, pos))
      check main == 2
      check back == 1
      check seen.len == Degree
      check pos notin seen

  test "adjacency is symmetric and every edge is incident to both its ends":
    for edge in 0 ..< Edges.len:
      let a = Edges[edge].a
      let b = Edges[edge].b
      check slotOf(a, edge) >= 0
      check slotOf(b, edge) >= 0
      check otherEnd(edge, a) == b
      check otherEnd(edge, b) == a
    ## Mobility is a road property, not a region property.
    for edge in 0 ..< Edges.len:
      check Edges[edge].mobility == (if Edges[edge].main: 250_000 else: 150_000)

  test "NeighboursOf is a fixed total order and names resolve":
    check NeighboursOf[2] == [1, 2, 8]
    check neighbours(2) == @[1, 3, 5]
    for pos in 0 ..< Regions:
      check positionOfName(RegionNames[pos]) == pos
    check positionOfName("  riverbend ") == 2
    check positionOfName("Nowhere") == -1

suite "seeded setup":
  test "the seat to position map is a bijection, stable, and seed-dependent":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var seen = initHashSet[int]()
      for seat in 0 ..< Seats:
        seen.incl(sim.posOf[seat])
        check sim.seatOf[sim.posOf[seat]] == seat
      check seen.len == Regions
      check sim.outbreakPos in 0 ..< Regions
      check sim.variantWeek in 8 .. 12
      let twin = initSim(fixtureConfig(seed = seed))
      check twin.posOf == sim.posOf
      check twin.outbreakPos == sim.outbreakPos
      check twin.variantWeek == sim.variantWeek
    var layouts = initHashSet[string]()
    for seed in 0 ..< 20:
      layouts.incl($initSim(fixtureConfig(seed = seed)).posOf)
    check layouts.len > 1

  test "week 0 compartments sum to Pop and one region is seeded hot":
    let sim = initSim(fixtureConfig(seed = 3))
    check sim.week == 0
    check sim.weeksPlayed == 0
    check sim.phase == phDials
    check sim.pendingSeats() == @[0, 1, 2, 3, 4, 5]
    var hot = 0
    for pos in 0 ..< Regions:
      let region = sim.regions[pos]
      check region.susceptible + region.infected + region.recovered +
        region.dead == Pop
      check region.dead == 0
      check region.gdp == 0
      check region.lockdown == 0
      check region.testing == 0
      check region.gates == [0, 0, 0]
      if region.infected > SeedInfected: inc hot
      ## Reported cases are already biased at testing 0.
      check region.confirmed == region.infected * DetectPpm[0] div Ppm
    check hot == 1
    check sim.regions[sim.outbreakPos].infected ==
      SeedInfected + OutbreakInfected
    check sim.events.len == 2
    check sim.events[0].kind == evStart
    check sim.events[1].kind == evWeek
    check sim.history.len == 1
    for seat in 0 ..< Seats:
      check sim.names[seat] == RegionNames[sim.posOf[seat]]

suite "resolution arithmetic":
  # A hand-computed week. Every region is pinned to the same state and the
  # same dials, so the arithmetic below is written out once and holds for all
  # six. Pre-resolution: S0 = 900_000, I0 = 100_000, alive = 1_000_000,
  # ledger = 1_000; lockdown 2, testing 1, every gate 2 at BOTH ends.
  #
  #   prev      = 100_000 * 1e6 / 1_000_000            = 100_000 ppm
  #   beta      = BetaPpm[2]                           = 640_000
  #   local     = (640_000 * 900_000 / 1e6) * 100_000 / 1e6
  #             = 576_000 * 100_000 / 1e6              =  57_600
  #   pass      = 120_000 + 880_000 * 0 / 1e6          = 120_000  (both ends shut)
  #   crossTerm = 700_000 * 100_000 / 1e6              =  70_000
  #   imp main  = (250_000 * 120_000 / 1e6) * 70_000 / 1e6 = 30_000 * 70_000 / 1e6 = 2_100
  #   imp back  = (150_000 * 120_000 / 1e6) * 70_000 / 1e6 = 18_000 * 70_000 / 1e6 = 1_260
  #   force     = 57_600 + 2*2_100 + 1_260             =  63_060   (under the 900_000 cap)
  #   newInf    = 900_000 * 63_060 / 1e6               =  56_754
  #   S         = 900_000 - 56_754                     = 843_246
  #   I(spread) = 100_000 + 56_754                     = 156_754
  #   sick      = min(600_000, 156_754 * 1_500_000/1e6)= 235_131
  #   output    = (800_000 * 1_000_000/1e6) * (1e6-235_131)/1e6 = 611_895
  #   gross     = 1_000 * 611_895 / 1e6                =     611
  #   spend     = 20 + 3*30 + 3*15                     =     155
  #   ledger    = 1_000 + 611 - 155                    =   1_456
  #   load      = 156_754 * 1e6 / 25_000               = 6_270_160  -> critical
  #   ifr       = 8_000 + 8_000 * 3_000_000/1e6        =  32_000
  #   resolved  = 100_000 * 350_000 / 1e6              =  35_000
  #   deaths    = 35_000 * 32_000 / 1e6                =   1_120
  #   recovered = 35_000 - 1_120                       =  33_880
  #   I(final)  = 156_754 - 35_000                     = 121_754
  #   confirmed = 121_754 * 350_000 / 1e6              =  42_613
  #   confNew   =  56_754 * 350_000 / 1e6              =  19_863
  proc pinned(): Sim =
    result = initSim(fixtureConfig(weeks = 20, seed = 3))
    for pos in 0 ..< Regions:
      result.regions[pos] = RegionState(
        susceptible: 900_000, infected: 100_000, recovered: 0, dead: 0,
        gdp: 1_000, lockdown: 0, testing: 0, gates: [0, 0, 0])
    result.history[^1].regions = result.regions

  test "one hand-computed week, field for field":
    var sim = pinned()
    sim.decideAll(flatDecision(lockdown = 2, testing = 1, gate = 2))
    check sim.week == 1
    check sim.weeksPlayed == 1
    for pos in 0 ..< Regions:
      let region = sim.regions[pos]
      check region.newInfections == 56_754
      check region.susceptible == 843_246
      check region.infected == 121_754
      check region.recovered == 33_880
      check region.dead == 1_120
      check region.deathsWeek == 1_120
      check region.grossGdp == 611
      check region.spendWeek == 155
      check region.gdp == 1_456
      check region.confirmed == 42_613
      check region.confirmedNew == 19_863
      check region.hospital == 3
      check region.susceptible + region.infected + region.recovered +
        region.dead == Pop

  test "the pieces of that week, on their own":
    check passPpm(2) == LeakPpm
    check passPpm(2) == 120_000
    check passPpm(0) == Ppm
    check passPpm(1) == 120_000 + (880_000 * 400_000) div Ppm
    check ifrPpm(HospitalCap) == BaseIfrPpm
    check ifrPpm(4 * HospitalCap) == 4 * BaseIfrPpm
    check ifrPpm(100 * HospitalCap) == 4 * BaseIfrPpm
    check ifrPpm(0) == BaseIfrPpm

  test "the leak: a sealed road still infects":
    ## Both ends shut, the neighbour at 20% prevalence, and this region as
    ## suppressed as the rules allow. It still takes cases.
    var sim = initSim(fixtureConfig(weeks = 20, seed = 5))
    for pos in 0 ..< Regions:
      sim.regions[pos] = RegionState(
        susceptible: Pop, infected: 0, recovered: 0, dead: 0,
        gdp: 0, lockdown: 0, testing: 0, gates: [0, 0, 0])
    ## Position 1 is the only hot region; position 0 borders it on a main road
    ## and has NOTHING of its own.
    sim.regions[1] = RegionState(
      susceptible: 800_000, infected: 200_000, recovered: 0, dead: 0,
      gdp: 0, lockdown: 0, testing: 0, gates: [0, 0, 0])
    sim.history[^1].regions = sim.regions
    sim.decideAll(flatDecision(lockdown = 4, testing = 3, gate = 2))
    for edge in 0 ..< Edges.len:
      check sim.effectiveGate(edge) == 2
    check sim.regions[0].newInfections > 0
    check sim.regions[0].infected > 0

  test "the tighter end governs the road":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 5))
    ## Position 0's roads: slot 0 -> 5 (edge 5), slot 1 -> 1 (edge 0),
    ## slot 2 -> 3 (edge 6).
    let seatOfZero = sim.seatOf[0]
    let seatOfOne = sim.seatOf[1]
    var closed = blankDecision()
    closed.borders = [-1, 2, -1]
    sim.applyDecision(seatOfZero, closed, true)
    check sim.effectiveGate(0) == 2
    var open = blankDecision()
    open.borders = [0, 0, 0]
    sim.applyDecision(seatOfOne, open, true)
    ## The looser end cannot re-open the road.
    check sim.regions[1].gates[slotOf(1, 0)] == 0
    check sim.effectiveGate(0) == 2
    check max(sim.regions[0].gates[slotOf(0, 0)],
      sim.regions[1].gates[slotOf(1, 0)]) == sim.effectiveGate(0)

  test "a region pays for the road its neighbour closed":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 5))
    ## Everyone open except position 0, which slams its edge-0 road shut.
    for seat in sim.pendingSeats():
      var decision = flatDecision()
      if sim.posOf[seat] == 0:
        decision.borders = [0, 2, 0]
      sim.applyDecision(seat, decision, true)
    ## Position 0 pays BorderOwnCost[2] = 30 on that road; position 1, which
    ## left every gate open, still pays BorderNeighbourCost[2] = 15.
    check sim.regions[0].spendWeek == BorderOwnCost[2]
    check sim.regions[1].spendWeek == BorderNeighbourCost[2]
    check sim.regions[2].spendWeek == 0

suite "aid":
  proc rich(): Sim =
    result = initSim(fixtureConfig(weeks = 20, seed = 11))
    for pos in 0 ..< Regions:
      result.regions[pos].gdp = 1_000
    result.history[^1].regions = result.regions

  test "a sender is clamped to 200 a week and to its own ledger":
    var sim = rich()
    let seat = sim.seatOf[0]
    var decision = flatDecision()
    decision.aid = @[AidEntry(to: 1, amount: 500)]
    sim.applyDecision(seat, decision, true)
    check sim.pendingDecision[0].aid.len == 1
    check sim.pendingDecision[0].aid[0].amount == MaxAidPerWeek
    check sim.pendingDecision[0].corrected

    var poor = rich()
    for pos in 0 ..< Regions:
      poor.regions[pos].gdp = 40
    var small = flatDecision()
    small.aid = @[AidEntry(to: 1, amount: 500)]
    poor.applyDecision(poor.seatOf[0], small, true)
    check poor.pendingDecision[0].aid[0].amount == 40

    var broke = rich()
    for pos in 0 ..< Regions:
      broke.regions[pos].gdp = -50
    var none = flatDecision()
    none.aid = @[AidEntry(to: 1, amount: 10)]
    broke.applyDecision(broke.seatOf[0], none, true)
    check broke.pendingDecision[0].aid.len == 0

  test "self aid is dropped and entries past the third are dropped":
    var sim = rich()
    var decision = flatDecision()
    decision.aid = @[
      AidEntry(to: 0, amount: 10),          # self
      AidEntry(to: 1, amount: 10),
      AidEntry(to: 2, amount: 10),
      AidEntry(to: 3, amount: 10),
      AidEntry(to: 4, amount: 10),          # the fourth surviving entry
    ]
    sim.applyDecision(sim.seatOf[0], decision, true)
    let kept = sim.pendingDecision[0].aid
    check kept.len == MaxAidEntries
    check kept[0].to == 1
    check kept[2].to == 3
    check sim.pendingDecision[0].corrected

  test "credits only move; the six ledgers sum invariantly":
    var sim = rich()
    let before = 6 * 1_000
    var pattern = @[
      @[AidEntry(to: 1, amount: 100), AidEntry(to: 2, amount: 60)],
      @[AidEntry(to: 3, amount: 200)],
      @[],
      @[AidEntry(to: 0, amount: 30)],
      @[AidEntry(to: 0, amount: 90), AidEntry(to: 5, amount: 90)],
      @[]
    ]
    for seat in sim.pendingSeats():
      var decision = flatDecision()
      decision.aid = pattern[sim.posOf[seat]]
      sim.applyDecision(seat, decision, true)
    var total = 0'i64
    var moved = 0'i64
    for pos in 0 ..< Regions:
      ## Undo the week's own economics so only the transfers remain.
      total += sim.regions[pos].gdp - sim.regions[pos].grossGdp +
        sim.regions[pos].spendWeek
      moved += sim.regions[pos].aidOut
    check total == before
    check moved == 100 + 60 + 200 + 30 + 90 + 90
    check sim.regions[0].aidIn == 30 + 90
    check sim.regions[0].aidOut == 160

  test "aid received this week cannot be re-sent this week":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 11))
    ## Position 0 is broke, position 1 is rich and sends it 200.
    sim.regions[1].gdp = 1_000
    sim.history[^1].regions = sim.regions
    for seat in sim.pendingSeats():
      var decision = flatDecision()
      if sim.posOf[seat] == 1:
        decision.aid = @[AidEntry(to: 0, amount: 200)]
      elif sim.posOf[seat] == 0:
        decision.aid = @[AidEntry(to: 2, amount: 200)]
      sim.applyDecision(seat, decision, true)
    ## Position 0's own ledger was 0 when it decided, so it forwarded nothing.
    check sim.regions[0].aidOut == 0
    check sim.regions[0].aidIn == 200
    check sim.regions[2].aidIn == 0

suite "scoring and endings":
  test "score is the ledger minus two credits a death, either sign":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 13))
    sim.regions[0].gdp = 10_000
    sim.regions[0].dead = 1_000
    sim.regions[1].gdp = 4_000
    sim.regions[1].dead = 9_000
    check sim.score(sim.seatOf[0]) == 10_000 - 2 * 1_000
    check sim.score(sim.seatOf[0]) > 0
    check sim.score(sim.seatOf[1]) == 4_000 - 2 * 9_000
    check sim.score(sim.seatOf[1]) < 0

  test "an episode completes after `weeks` and results carry the closed key set":
    var sim = initSim(fixtureConfig(weeks = 6, seed = 5))
    for week in 0 ..< 6:
      check not sim.done
      sim.decideAll(flatDecision(lockdown = 1, testing = 1))
    check sim.done
    check sim.reason == "complete"
    check sim.weeksPlayed == 6
    check sim.week == 6
    check sim.history.len == 7
    check sim.events[^1].kind == evEnd
    check sim.events[^2].kind == evWeek
    check sim.events[^2].week == 6
    let results = sim.resultsJson()
    var keys: seq[string]
    for key in results.keys:
      keys.add(key)
    keys.sort()
    check keys == @["deaths", "gdp", "maxWeeks", "names", "reason", "regions",
      "scores", "totalDeaths", "totalGdp", "weeks"]
    var totalDeaths = 0'i64
    var totalGdp = 0'i64
    for seat in 0 ..< Seats:
      check results["scores"][seat].getBiggestInt() == sim.score(seat)
      check results["gdp"][seat].getBiggestInt() ==
        sim.regions[sim.posOf[seat]].gdp
      check results["deaths"][seat].getBiggestInt() ==
        sim.regions[sim.posOf[seat]].dead
      check results["regions"][seat].getStr() == sim.regionOf(seat)
      totalDeaths += results["deaths"][seat].getBiggestInt()
      totalGdp += results["gdp"][seat].getBiggestInt()
    check results["totalDeaths"].getBiggestInt() == totalDeaths
    check results["totalGdp"].getBiggestInt() == totalGdp
    check results["weeks"].getInt() == 6
    check results["maxWeeks"].getInt() == 6
    check results["reason"].getStr() == "complete"
    expect ContagionError:
      sim.applyDecision(0, flatDecision(), true)

  test "endEarly settles between weeks with the weeks played":
    var sim = initSim(fixtureConfig(weeks = 10, seed = 5))
    sim.decideAll(flatDecision())
    sim.decideAll(flatDecision())
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.weeksPlayed == 2
    check sim.pendingSeats().len == 0
    let results = sim.resultsJson()
    check results["reason"].getStr() == "deadline"
    check results["weeks"].getInt() < results["maxWeeks"].getInt()
    ## Idempotent, and no third reason exists.
    sim.endEarly()
    check sim.reason == "deadline"
    check sim.events[^1].kind == evEnd

suite "decisions":
  test "hard-invalid decisions raise and change nothing":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    expect ContagionError:
      sim.applyDecision(0, flatDecision(lockdown = 5), false)
    expect ContagionError:
      sim.applyDecision(0, flatDecision(lockdown = -1), false)
    expect ContagionError:
      sim.applyDecision(0, flatDecision(testing = 4), false)
    expect ContagionError:
      sim.applyDecision(0, flatDecision(gate = 3), false)
    expect ContagionError:
      sim.applyDecision(9, flatDecision(), false)
    check sim.pendingSeats() == @[0, 1, 2, 3, 4, 5]
    sim.applyDecision(0, flatDecision(), false)
    expect ContagionError:
      sim.applyDecision(0, flatDecision(), false)
    check sim.pendingSeats() == @[1, 2, 3, 4, 5]
    check sim.week == 0

  test "an unmentioned road keeps last week's gate":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    let seat = sim.seatOf[0]
    var shut = blankDecision()
    shut.borders = [2, 1, 0]
    sim.applyDecision(seat, shut, true)
    check sim.regions[0].gates == [2, 1, 0]
    for other in sim.pendingSeats():
      sim.applyDecision(other, flatDecision(), true)
    ## Week 1: say nothing about any road.
    var silent = blankDecision()
    silent.borders = [-1, -1, -1]
    sim.applyDecision(sim.seatOf[0], silent, true)
    check sim.regions[0].gates == [2, 1, 0]
    ## And the event records the standing closure, not the silence.
    check sim.events[^1].decision.borders == [2, 1, 0]

  test "say is capped on a rune boundary, flattened, and silenced with talk off":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    var long = ""
    for index in 0 ..< 400:
      long.add("é")
    var loud = flatDecision()
    loud.say = "  hello\nthere  "
    sim.applyDecision(0, loud, false)
    var shout = flatDecision()
    shout.say = long
    sim.applyDecision(1, shout, false)
    check sim.says[sim.posOf[0]] == "hello there"
    check sim.says[sim.posOf[1]].runeLen == MaxSayLen
    check sim.says[sim.posOf[1]].validateUtf8() == -1
    for event in sim.events:
      check event.decision.say.validateUtf8() == -1
      check event.text.validateUtf8() == -1
    var quiet = initSim(fixtureConfig(weeks = 8, seed = 1, talk = false))
    var muted = flatDecision()
    muted.say = "hello"
    quiet.applyDecision(0, muted, false)
    check quiet.says[quiet.posOf[0]] == ""

  test "talk reaches the whole table next week; notes persist":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    let speaker = sim.seatOf[2]
    for seat in sim.pendingSeats():
      var decision = flatDecision()
      if seat == speaker:
        decision.say = "Riverbend is at 2%"
        decision.notes = "note A"
      sim.applyDecision(seat, decision, true)
    check sim.week == 1
    check sim.heard[2] == "Riverbend is at 2%"
    check sim.notes[speaker] == "note A"
    ## Public: every seat hears it, not just the neighbours.
    let state = sim.tableStateJson()
    for seat in 0 ..< Seats:
      check state["seats"][seat]["heard"].len == 1
      check state["seats"][seat]["heard"][0]["say"].getStr() ==
        "Riverbend is at 2%"
    sim.decideAll(flatDecision())
    check sim.notes[speaker] == "note A"
    check sim.heard[2] == ""

  test "notes are capped on a rune boundary at 700":
    var sim = initSim(fixtureConfig(weeks = 8, seed = 1))
    var long = ""
    for index in 0 ..< 900:
      long.add("é")
    var decision = flatDecision()
    decision.notes = long
    sim.applyDecision(0, decision, false)
    check sim.notes[0].runeLen == MaxNotesLen
    check sim.notes[0].validateUtf8() == -1

suite "simultaneity and determinism":
  test "the apply order across seats cannot change the outcome":
    let config = fixtureConfig(weeks = 8, seed = 21)
    proc play(order: seq[int]): string =
      var sim = initSim(config)
      for week in 0 ..< 4:
        for seat in order:
          var decision = flatDecision(lockdown = seat mod 5,
            testing = seat mod 4, gate = seat mod 3)
          decision.say = "seat " & $seat
          sim.applyDecision(seat, decision, true)
      $sim.tableStateJson()
    let straight = play(@[0, 1, 2, 3, 4, 5])
    check play(@[5, 4, 3, 2, 1, 0]) == straight
    check play(@[3, 0, 5, 1, 4, 2]) == straight

  test "the same seed and the same decisions give the same event log":
    let config = fixtureConfig(weeks = 6, seed = 77)
    proc run(): string =
      var sim = initSim(config)
      var week = 0
      while not sim.done:
        for seat in sim.pendingSeats():
          var decision = flatDecision(lockdown = (week + seat) mod 5,
            testing = (week + seat) mod 4, gate = (week + seat) mod 3)
          sim.applyDecision(seat, decision, true)
        inc week
      var events = newJArray()
      for event in sim.events:
        events.add(event.eventToJson())
      $events
    check run() == run()

suite "replay":
  test "a recorded episode re-derives frame by frame":
    let config = fixtureConfig(weeks = 8, seed = 31)
    var live = initSim(config)
    var week = 0
    while not live.done:
      for seat in live.pendingSeats():
        var decision = flatDecision(lockdown = (week + seat) mod 5,
          testing = (week * 2 + seat) mod 4, gate = (week + seat) mod 3)
        if seat == 0:
          decision.say = "week " & $week
          decision.notes = "ledger watch " & $week
          decision.aid = @[AidEntry(to: (live.posOf[0] + 1) mod Regions,
            amount: 25)]
        live.applyDecision(seat, decision, false)
      inc week
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].done
    check frames[^1].reason == "complete"
    ## And through the JSON the replay actually carries.
    var roundTripped: seq[GameEvent]
    for event in live.events:
      roundTripped.add(eventFromJson(event.eventToJson()))
    let viaJson = replayMatch(config, roundTripped)
    check $viaJson[^1].tableStateJson() == $live.tableStateJson()

  test "a recorded deadline stop is honoured":
    let config = fixtureConfig(weeks = 8, seed = 31)
    var short = initSim(config)
    short.decideAll(flatDecision())
    short.endEarly()
    let frames = replayMatch(config, short.events)
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check frames[^1].weeksPlayed == 1

  test "a tampered week event is rejected":
    let config = fixtureConfig(weeks = 6, seed = 31)
    var live = initSim(config)
    live.decideAll(flatDecision(lockdown = 1))
    var events = live.events
    check events[^1].kind == evWeek
    events[^1].regions[0].infected += 1
    expect ContagionError:
      discard replayMatch(config, events)
    var flipped = live.events
    flipped[^1].variant = not flipped[^1].variant
    expect ContagionError:
      discard replayMatch(config, flipped)

  test "every event kind round-trips through JSON":
    var say = ""
    for index in 0 ..< MaxSayLen:
      say.add("é")
    var notes = ""
    for index in 0 ..< MaxNotesLen:
      notes.add("漢")
    var decision = blankDecision()
    decision.lockdown = 3
    decision.testing = 2
    decision.borders = [2, 0, 1]
    decision.aid = @[
      AidEntry(to: 1, amount: 120),
      AidEntry(to: 3, amount: 50),
      AidEntry(to: 4, amount: 30)
    ]
    decision.say = say
    decision.notes = notes
    decision.corrected = true
    var region = RegionState(
      susceptible: 803_110, infected: 8_210, recovered: 187_180, dead: 1_500,
      gdp: 14_402, lockdown: 3, testing: 2, gates: [2, 0, 1],
      newInfections: 1_249, deathsWeek: 37, confirmed: 5_337,
      confirmedNew: 812, grossGdp: 540, spendWeek: 95, aidIn: 150, aidOut: 0,
      hospital: 1)
    var samples: seq[GameEvent]
    samples.add(GameEvent(kind: evStart, week: -1, seat: -1, pos: -1))
    var weekEvent = GameEvent(kind: evWeek, week: 7, seat: -1, pos: -1,
      variant: true)
    for pos in 0 ..< Regions:
      weekEvent.regions.add(region)
    samples.add(weekEvent)
    samples.add(GameEvent(kind: evDial, week: 7, seat: 4, pos: 2,
      decision: decision, scripted: true, text: notes))
    samples.add(GameEvent(kind: evEnd, week: 20, seat: -1, pos: -1,
      text: "complete"))
    for event in samples:
      let node = event.eventToJson()
      check ($node).validateUtf8() == -1
      let back = eventFromJson(node)
      check back.kind == event.kind
      check back.week == event.week
      check back.seat == event.seat
      check back.pos == event.pos
      check back.variant == event.variant
      check back.text == event.text
      check back.scripted == event.scripted
      check back.regions.len == event.regions.len
      for index in 0 ..< event.regions.len:
        check back.regions[index] == event.regions[index]
      if event.kind == evDial:
        check back.decision.lockdown == event.decision.lockdown
        check back.decision.testing == event.decision.testing
        check back.decision.borders == event.decision.borders
        check back.decision.aid == event.decision.aid
        check back.decision.say == event.decision.say
        check back.decision.say.runeLen == MaxSayLen
        check back.decision.notes.runeLen == MaxNotesLen
        check back.decision.corrected

suite "viewer state":
  test "curves are revealed only up to the current week":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 41))
    check sim.tableStateJson()["curves"]["infected"][0].len == 1
    sim.decideAll(flatDecision(lockdown = 1))
    let state = sim.tableStateJson()
    check state["week"].getInt() == 1
    check state["weeks"].getInt() == 20
    check state["curves"]["infected"].len == Regions
    for pos in 0 ..< Regions:
      check state["curves"]["infected"][pos].len == 2
      check state["curves"]["confirmed"][pos].len == 2
      check state["curves"]["deaths"][pos].len == 2
      check state["curves"]["gdp"][pos].len == 2
    check state["edges"].len == Edges.len
    check state["regions"].len == Regions
    check state["hospitalCap"].getBiggestInt() == HospitalCap
    for seat in 0 ..< Seats:
      check state["seats"][seat]["pos"].getInt() == sim.posOf[seat]
      check state["seats"][seat]["gates"].len == Degree
      check state["seats"][seat]["pending"].getBool()
    check state["posSeat"][0].getInt() == sim.seatOf[0]

  test "the player view never carries a true infection count":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 41))
    sim.decideAll(flatDecision(lockdown = 1, testing = 2))
    for seat in 0 ..< Seats:
      let view = sim.playerViewJson(seat)
      let text = $view
      check "infected" notin text
      check "susceptible" notin text
      check "recovered" notin text
      check view["region"].getStr() == sim.regionOf(seat)
      check view["own"]["confirmed"].getBiggestInt() ==
        sim.regions[sim.posOf[seat]].confirmed
      check view["others"].len == Regions - 1
      for other in view["others"]:
        check not other.hasKey("hospital")
        check not other.hasKey("notes")
      ## And no policy display name leaks into the seat's world.
      for player in sim.config.players:
        check player.name notin text
