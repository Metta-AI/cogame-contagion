## The replay bytes are the whole product: the hosted static viewer is handed
## nothing else. So they must be strict UTF-8 JSON (docker_smoke.sh parses
## them with SMOKE_REQUIRE_REPLAY_JSON=1), they must carry every field the
## viewer needs, and the wasm module's Nim path must re-derive exactly the
## states the live server had.

import std/[json, unicode, unittest]
import support/helpers

proc emojiSay(): string =
  ## 4-byte code points and a combining mark, right up against the cap.
  var text = ""
  while text.runeLen < MaxSayLen + 40:
    text.add("🦠")
    text.add("e\u0301")
    text.add("漢")
  text

proc emojiNotes(): string =
  var text = ""
  while text.runeLen < MaxNotesLen + 60:
    text.add("🏥")
    text.add("a\u0308")
    text.add("région")
  text

proc playedEpisode(weeks = 8, seed = 61): Sim =
  result = initSim(fixtureConfig(weeks = weeks, seed = seed))
  var week = 0
  while not result.done:
    for seat in result.pendingSeats():
      var decision = flatDecision(lockdown = (week + seat) mod 5,
        testing = (week + seat * 2) mod 4, gate = (week + seat) mod 3)
      decision.say = emojiSay()
      decision.notes = emojiNotes()
      if seat mod 2 == 0:
        decision.aid = @[AidEntry(
          to: (result.posOf[seat] + 1) mod Regions, amount: 15)]
      result.applyDecision(seat, decision, false)
    inc week

suite "the replay bytes":
  test "every recorded string is valid UTF-8, cut on a rune boundary":
    let sim = playedEpisode()
    for event in sim.events:
      check event.decision.say.validateUtf8() == -1
      check event.decision.notes.validateUtf8() == -1
      check event.text.validateUtf8() == -1
      if event.kind == evDial:
        ## The cap is in RUNES, and a cut never leaves half a code point.
        check event.decision.say.runeLen <= MaxSayLen
        check event.text.runeLen <= MaxNotesLen
        check event.decision.say.runeLen == MaxSayLen
        check event.text.runeLen == MaxNotesLen

  test "the serialised payload is strict UTF-8 JSON and round-trips stably":
    let sim = playedEpisode()
    let payload = sim.replayPayloadJson()
    let bytes = $payload
    check bytes.validateUtf8() == -1
    check bytes.len > 1000
    let reparsed = parseJson(bytes)
    check $reparsed == bytes
    ## And the bytes decode as UTF-8 rune by rune with nothing left over.
    var runes = 0
    for rune in bytes.runes:
      inc runes
    check runes > 0

  test "the payload carries every field the static viewer needs":
    let sim = playedEpisode(weeks = 6, seed = 77)
    let payload = sim.replayPayloadJson()
    check payload["protocol"].getStr() == "contagion.replay.v1"
    check payload["rules"].getStr() == RulesVersion
    check payload["names"].len == Seats
    check payload["policyNames"].len == Seats
    for seat in 0 ..< Seats:
      check payload["names"][seat].getStr() == sim.regionOf(seat)
      check payload["policyNames"][seat].getStr() ==
        sim.config.players[seat].name
    check payload["config"]["seed"].getInt() == 77
    check payload["config"]["weeks"].getInt() == 6
    check payload["config"]["talk"].getBool()
    check payload["config"]["sampled"].getBool()
    check payload.hasKey("results")
    check payload["results"]["reason"].getStr() == "complete"
    var weekEvents = 0
    var dialEvents = 0
    for event in payload["events"]:
      case event["kind"].getStr()
      of "week":
        inc weekEvents
        check event["regions"].len == Regions
      of "dial":
        inc dialEvents
        check event.hasKey("borders")
        check event["borders"].len == Degree
        check event.hasKey("aid")
      else: discard
    ## One week event per observed week, including the final observed week.
    check weekEvents == 6 + 1
    check dialEvents == 6 * Seats

  test "the wasm module's Nim path re-derives the live states exactly":
    ## This is literally what replay-viewer/contagion_replay.nim does: rebuild
    ## the config from the payload, parse every event, replayMatch, and emit
    ## the state array.
    let sim = playedEpisode(weeks = 8, seed = 61)
    let payload = parseJson($sim.replayPayloadJson())
    var config = defaultGameConfig()
    config.weeks = payload["config"]{"weeks"}.getInt(20)
    config.seed = payload["config"]{"seed"}.getInt(0)
    config.talk = payload["config"]{"talk"}.getBool(true)
    config.sampled = true
    for name in payload["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for node in payload["events"]:
      events.add(eventFromJson(node))
    check events.len == payload["events"].len
    var states = newJArray()
    for frame in replayMatch(config, events):
      states.add(frame.tableStateJson())
    check states.len == events.len + 1
    check $states[^1] == $sim.tableStateJson()

  test "a replay written under different rules is still self-describing":
    ## `rules` is what lets a future viewer refuse a replay written under
    ## different constants instead of drawing nonsense.
    let sim = playedEpisode(weeks = 6, seed = 5)
    var payload = sim.replayPayloadJson()
    check payload["rules"].getStr() == "contagion.rules.v1"
    payload["rules"] = %"contagion.rules.v99"
    check parseJson($payload)["rules"].getStr() == "contagion.rules.v99"

  test "a deadline replay replays as a deadline":
    var sim = initSim(fixtureConfig(weeks = 12, seed = 5))
    sim.decideAll(flatDecision(lockdown = 2, testing = 1))
    sim.decideAll(flatDecision(lockdown = 2, testing = 1))
    sim.decideAll(flatDecision(lockdown = 2, testing = 1))
    sim.endEarly()
    let payload = parseJson($sim.replayPayloadJson())
    var config = fixtureConfig(weeks = 12, seed = 5)
    var events: seq[GameEvent]
    for node in payload["events"]:
      events.add(eventFromJson(node))
    let frames = replayMatch(config, events)
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check frames[^1].weeksPlayed == 3
    check payload["results"]["reason"].getStr() == "deadline"
    check payload["results"]["weeks"].getInt() <
      payload["results"]["maxWeeks"].getInt()
