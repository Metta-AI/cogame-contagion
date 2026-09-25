## The scripted baselines must play whole episodes without ever proposing an
## illegal move — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path. They
## must also be honest: a baseline that peeked at the true infection counts
## would be cheating, and the game would stop being about information.

import std/[json, monotimes, strutils, times, unicode, unittest]
import support/helpers
import contagion/player_policy

proc totals(sim: Sim): tuple[deaths: int64, meanScore: int64] =
  var deaths = 0'i64
  var score = 0'i64
  for seat in 0 ..< Seats:
    deaths += sim.regions[sim.posOf[seat]].dead
    score += sim.score(seat)
  (deaths, score div Seats)

suite "scripted baselines":
  test "six sentinels, six laggards and a 3/3 mix all play legally":
    for seed in [1, 7, 42, 1234]:
      for kinds in [
        [skSentinel, skSentinel, skSentinel, skSentinel, skSentinel,
          skSentinel],
        [skLaggard, skLaggard, skLaggard, skLaggard, skLaggard, skLaggard],
        [skSentinel, skLaggard, skSentinel, skLaggard, skSentinel, skLaggard]
      ]:
        let sim = playScripted(fixtureConfig(weeks = 20, seed = seed), kinds)
        check sim.done
        check sim.reason == "complete"
        check sim.weeksPlayed == 20
        var dials = 0
        for event in sim.events:
          if event.kind != evDial:
            continue
          inc dials
          check event.decision.lockdown in 0 .. 4
          check event.decision.testing in 0 .. 3
          for slot in 0 ..< Degree:
            check event.decision.borders[slot] in 0 .. 2
          check event.decision.aid.len == 0
          check event.decision.say.len == 0
        check dials == 20 * Seats
        for pos in 0 ..< Regions:
          ## No ledger was ever drained by aid, because none was sent.
          check sim.regions[pos].aidIn == 0
          check sim.regions[pos].aidOut == 0

  test "the baselines see only what a seat sees":
    ## Two sims with identical REPORTED numbers and identical published dials,
    ## but wildly different hidden truth. A baseline that peeked would differ;
    ## these must be byte-identical.
    for seed in [1, 7, 42, 1234]:
      var honest = initSim(fixtureConfig(weeks = 20, seed = seed))
      honest.decideAll(flatDecision(lockdown = 1, testing = 2))
      honest.decideAll(flatDecision(lockdown = 1, testing = 2))
      var hidden = honest
      for pos in 0 ..< Regions:
        ## Move the truth around without touching confirmed / testing / dead.
        hidden.regions[pos].infected = honest.regions[pos].infected * 3 + 17
        hidden.regions[pos].susceptible =
          honest.regions[pos].susceptible - honest.regions[pos].infected * 2
        hidden.regions[pos].recovered = honest.regions[pos].recovered + 999
        hidden.regions[pos].newInfections =
          honest.regions[pos].newInfections * 5
        for week in 0 ..< hidden.history.len:
          hidden.history[week].regions[pos].infected =
            honest.history[week].regions[pos].infected * 3 + 17
          hidden.history[week].regions[pos].recovered =
            honest.history[week].regions[pos].recovered + 999
      for seat in 0 ..< Seats:
        for kind in [skSentinel, skLaggard]:
          check scriptedDecision(honest, seat, kind) ==
            scriptedDecision(hidden, seat, kind)

  test "the laggard is the leaky neighbour it is advertised as":
    var sim = initSim(fixtureConfig(weeks = 20, seed = 7))
    var locked = 0
    while not sim.done:
      for seat in sim.pendingSeats():
        let decision = scriptedDecision(sim, seat, skLaggard)
        check decision.testing == 0
        check decision.borders == [0, 0, 0]
        check decision.lockdown in [0, 3]
        if seat == 0 and decision.lockdown == 3:
          inc locked
        sim.applyDecision(seat, decision, true)
    ## Lockdown 3 for exactly three weeks, once, then open forever.
    check locked == 3

  test "suppression pays: laggards die more and score less, every seed":
    for seed in [1, 7, 42, 1234]:
      let sentinels = playScripted(fixtureConfig(weeks = 20, seed = seed),
        [skSentinel, skSentinel, skSentinel, skSentinel, skSentinel,
          skSentinel])
      let laggards = playScripted(fixtureConfig(weeks = 20, seed = seed),
        [skLaggard, skLaggard, skLaggard, skLaggard, skLaggard, skLaggard])
      let good = totals(sentinels)
      let bad = totals(laggards)
      echo "seed ", seed, ": sentinel deaths ", good.deaths, " mean score ",
        good.meanScore, " | laggard deaths ", bad.deaths, " mean score ",
        bad.meanScore
      check bad.deaths > good.deaths
      check bad.meanScore < good.meanScore

  test "doing nothing is catastrophic and hard suppression is not":
    ## The calibration the design note claims: an untouched dial loses more to
    ## the death penalty than the region ever earned, and locking down hard
    ## for the whole episode does not.
    var idle = initSim(fixtureConfig(weeks = 20, seed = 7))
    while not idle.done:
      idle.decideAll(flatDecision(lockdown = 0, testing = 0, gate = 0))
    var shut = initSim(fixtureConfig(weeks = 20, seed = 7))
    while not shut.done:
      shut.decideAll(flatDecision(lockdown = 4, testing = 2, gate = 0))
    echo "idle mean score ", totals(idle).meanScore, " deaths ",
      totals(idle).deaths, " | locked mean score ", totals(shut).meanScore,
      " deaths ", totals(shut).deaths
    check totals(idle).meanScore < 0
    check totals(shut).meanScore > totals(idle).meanScore
    check totals(shut).deaths < totals(idle).deaths

  test "a forty-week scripted episode resolves in well under 50 ms":
    ## The offline-certification path must never be the slow thing.
    let started = getMonoTime()
    let sim = playScripted(fixtureConfig(weeks = 40, seed = 99),
      [skSentinel, skLaggard, skSentinel, skLaggard, skSentinel, skLaggard])
    let elapsed = (getMonoTime() - started).inMilliseconds
    check sim.weeksPlayed == 40
    echo "40-week scripted episode: ", elapsed, " ms"
    check elapsed < 50

suite "reply parsing":
  proc probe(): Sim =
    ## Seat 0 governs a known position with a known ledger, so the aid and
    ## border assertions below can name real roads.
    result = initSim(fixtureConfig(weeks = 20, seed = 3))
    for pos in 0 ..< Regions:
      result.regions[pos].gdp = 1_000
    result.history[^1].regions = result.regions

  test "dials are coerced from int, numeric string and float":
    let sim = probe()
    check parseDecision(sim, 0,
      parseJson("""{"lockdown": 3, "testing": 2}""")).lockdown == 3
    check parseDecision(sim, 0,
      parseJson("""{"lockdown": "3", "testing": 2}""")).lockdown == 3
    check parseDecision(sim, 0,
      parseJson("""{"lockdown": 2.6, "testing": 2}""")).lockdown == 3
    check parseDecision(sim, 0,
      parseJson("""{"lockdown": " 1 ", "testing": "0"}""")).testing == 0

  test "out of range and unparseable dials are hard-invalid":
    let sim = probe()
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"lockdown": 5,
        "testing": 1}"""))
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"lockdown": -1,
        "testing": 1}"""))
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"lockdown": "soon",
        "testing": 1}"""))
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"testing": 1}"""))
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"lockdown": 1}"""))
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"lockdown": 1,
        "testing": 4}"""))
    ## Structure, not content: these two are hard-invalid too.
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"lockdown": 1,
        "testing": 1, "borders": 3}"""))
    expect ContagionError:
      discard parseDecision(sim, 0, parseJson("""{"lockdown": 1,
        "testing": 1, "aid": {"to": "Riverbend"}}"""))

  test "soft corrections are applied and marked":
    let sim = probe()
    let pos = sim.posOf[0]
    let mine = RegionNames[pos]
    let neighbour = RegionNames[neighbours(pos)[0]]
    let stranger = RegionNames[(pos + 2) mod Regions]   # not a neighbour

    ## An unknown road is ignored, not fatal.
    let unknown = parseDecision(sim, 0, parseJson(
      """{"lockdown": 1, "testing": 1, "borders": {"Atlantis": 2}}"""))
    check unknown.corrected
    check unknown.borders == [-1, -1, -1]

    ## A gate of 7 is clamped to 2.
    let clamped = parseDecision(sim, 0, parseJson(
      """{"lockdown": 1, "testing": 1, "borders": {"""" & neighbour &
      """": 7}}"""))
    check clamped.corrected
    check clamped.borders[0] == 2

    ## Self aid is dropped, and so is aid to a region that is not on the map.
    let selfAid = parseDecision(sim, 0, parseJson(
      """{"lockdown": 1, "testing": 1, "aid": [{"to": """" & mine &
      """", "amount": 50}, {"to": "Atlantis", "amount": 50}]}"""))
    check selfAid.corrected
    check selfAid.aid.len == 0

    ## Aid to a real, distant region is fine — the graph does not bound it.
    let far = parseDecision(sim, 0, parseJson(
      """{"lockdown": 1, "testing": 1, "aid": [{"to": """" & stranger &
      """", "amount": 50}]}"""))
    check far.aid.len == 1
    check far.aid[0].to == positionOfName(stranger)

    ## A negative amount is dropped.
    let negative = parseDecision(sim, 0, parseJson(
      """{"lockdown": 1, "testing": 1, "aid": [{"to": """" & neighbour &
      """", "amount": -5}]}"""))
    check negative.corrected
    check negative.aid.len == 0

  test "free text is truncated on rune boundaries":
    let sim = probe()
    var long = ""
    for index in 0 ..< 400:
      long.add("é")
    var notes = ""
    for index in 0 ..< 900:
      notes.add("漢")
    let decision = parseDecision(sim, 0, %*{
      "lockdown": 1, "testing": 1, "say": long, "notes": notes})
    check decision.say.runeLen == MaxSayLen
    check decision.notes.runeLen == MaxNotesLen
    check decision.say.validateUtf8() == -1
    check decision.notes.validateUtf8() == -1
    check cleanText(long, MaxSayLen).runeLen == MaxSayLen
    check cleanText(notes, MaxNotesLen).runeLen == MaxNotesLen
    check cleanText("short", MaxSayLen) == "short"

  test "a parsed reply is always a legal move":
    var sim = probe()
    let pos = sim.posOf[0]
    let neighbour = RegionNames[neighbours(pos)[1]]
    let decision = parseDecision(sim, 0, %*{
      "lockdown": 4, "testing": 3,
      "borders": {neighbour: 9},
      "aid": [{"to": neighbour, "amount": 100000}],
      "say": "sealing the north road",
      "notes": "keep an eye on the ledger"})
    sim.applyDecision(0, decision, false)
    check sim.regions[pos].lockdown == 4
    check sim.regions[pos].gates[1] == 2
    check sim.pendingDecision[pos].aid[0].amount == MaxAidPerWeek

  test "PLAYER_SCRIPTED values map to the two baselines":
    check parseScriptKind("1") == skSentinel
    check parseScriptKind("true") == skSentinel
    check parseScriptKind("yes") == skSentinel
    check parseScriptKind("sentinel") == skSentinel
    check parseScriptKind(" LAGGARD ") == skLaggard
    check parseScriptKind("") == skNone
    check parseScriptKind("something else") == skNone

  test "both player baselines match the rules from private views":
    for seed in [1, 7, 42, 1234]:
      var sim = initSim(fixtureConfig(weeks = 20, seed = seed))
      while not sim.done:
        let snapshot = sim
        for seat in snapshot.pendingSeats():
          let view = snapshot.playerViewJson(seat)
          for kind in [skSentinel, skLaggard]:
            let action = scriptedActionFromView(view, kind)
            let parsed = parseDecision(snapshot, seat, action)
            check parsed == scriptedDecision(snapshot, seat, kind)
          let decision = scriptedDecision(snapshot, seat,
            if seat mod 2 == 0: skSentinel else: skLaggard)
          sim.applyDecision(seat, decision, true)

  test "player prompts consume only the private observation":
    let sim = initSim(fixtureConfig(weeks = 8, seed = 7))
    let view = sim.playerViewJson(0)
    let (system, user) = promptsFromView(view, "operator says hi")
    check sim.regionOf(0) in system
    check "operator says hi" in user
    check "confirmed" in user
    check "infected" notin user
    for player in sim.config.players:
      check player.name notin user
