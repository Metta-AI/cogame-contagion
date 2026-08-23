## Shared fixtures for the Contagion tests. Lives in a SUBDIRECTORY on
## purpose: `ci.yml` runs every `tests/*.nim` as a standalone program, and a
## helper module sitting in that glob would be executed as a test.

import std/[json, unittest]
import contagion/[llm, sim]

export json, sim, llm

proc fixtureConfig*(weeks = 20, seed = 0, talk = true): GameConfig =
  result = defaultGameConfig()
  result.weeks = weeks
  result.seed = seed
  result.talk = talk
  ## Pinned, so these tests exercise the rules rather than the pacing cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc flatDecision*(lockdown = 0, testing = 0, gate = 0): Decision =
  result = blankDecision()
  result.lockdown = lockdown
  result.testing = testing
  result.borders = [gate, gate, gate]

proc decideAll*(sim: var Sim, decision: Decision) =
  ## Every pending seat submits the same dials; the sixth call resolves.
  for seat in sim.pendingSeats():
    sim.applyDecision(seat, decision, true)

proc playScripted*(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  ## A whole episode on the scripted baselines. `applyDecision` raises on
  ## anything illegal, so a completed episode IS the legality assertion.
  result = initSim(config)
  while not result.done:
    for seat in result.pendingSeats():
      let decision = scriptedDecision(result, seat, kinds[seat])
      check decision.say.len == 0
      check decision.notes.len == 0
      check decision.aid.len == 0
      result.applyDecision(seat, decision, true)

proc replayPayloadJson*(sim: Sim): JsonNode =
  ## The bytes the server writes, built from a finished sim.
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policyNames = newJArray()
  for player in sim.config.players:
    policyNames.add(%player.name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  %*{
    "protocol": "contagion.replay.v1",
    "rules": RulesVersion,
    "names": names,
    "policyNames": policyNames,
    "config": {
      "weeks": sim.config.weeks,
      "seed": sim.config.seed,
      "talk": sim.config.talk,
      "sampled": true
    },
    "events": events,
    "results": sim.resultsJson()
  }
