## Persistent numeric decision bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:contagion-train-bridge tools/train_bridge.nim

import std/[json, os]
import contagion/[llm, sim]

const OperatorPrompt =
  "Protect your region's health and economy using the published case reports."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc publicRegion(sim: Sim, pos: int): JsonNode =
  let region = sim.regions[pos]
  %*{"position": pos, "name": RegionNames[pos],
    "confirmed": region.confirmed, "confirmed_new": region.confirmedNew,
    "deaths": region.dead, "gdp": region.gdp,
    "score": sim.score(sim.seatOf[pos]),
    "lockdown": region.lockdown, "testing": region.testing,
    "gates": region.gates}

proc decision(sim: Sim, seat, id: int): JsonNode =
  let pos = sim.posOf[seat]
  let own = sim.regions[pos]
  var table = newJArray()
  for region in 0 ..< Regions:
    table.add(sim.publicRegion(region))
  %*{
    "kind": "decision", "game": "contagion", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": sim.week,
    "semantic_view": {"week": sim.week, "weeks": sim.config.weeks,
      "your_position": pos, "variant_active": sim.variantActive(),
      "table": table, "own_hospital": own.hospital,
      "own_gross_gdp": own.grossGdp, "own_spend": own.spendWeek,
      "own_aid_in": own.aidIn, "own_aid_out": own.aidOut},
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(sim, seat)},
      {"role": "user", "content": userPrompt(sim, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object",
      "required": ["lockdown", "testing", "gate0", "gate1", "gate2"],
      "properties": {
        "lockdown": {"type": "integer", "enum": [0, 1, 2, 3, 4]},
        "testing": {"type": "integer", "enum": [0, 1, 2, 3]},
        "gate0": {"type": "integer", "enum": [-1, 0, 1, 2]},
        "gate1": {"type": "integer", "enum": [-1, 0, 1, 2]},
        "gate2": {"type": "integer", "enum": [-1, 0, 1, 2]}
      }},
    "typed_question": newJNull()
  }

proc encoding(sim: Sim, seat, id: int, variant: string): JsonNode =
  let pos = sim.posOf[seat]
  let own = sim.regions[pos]
  var values = newJArray()
  for name in ["standard", "sprint"]:
    values.add(%(if variant == name: 1 else: 0))
  for region in 0 ..< Regions:
    values.add(%(if region == pos: 1 else: 0))
  for value in [sim.week, sim.config.weeks,
      (if sim.variantActive(): 1 else: 0)]:
    values.add(%value)
  for region in 0 ..< Regions:
    let state = sim.regions[region]
    for value in [state.confirmed, state.confirmedNew, state.dead,
        state.gdp, sim.score(sim.seatOf[region]),
        int64(state.lockdown), int64(state.testing),
        int64(state.gates[0]), int64(state.gates[1]),
        int64(state.gates[2])]:
      values.add(%value)
  for value in [int64(own.hospital), own.grossGdp, own.spendWeek,
      own.aidIn, own.aidOut]:
    values.add(%value)
  for slot in 0 ..< Degree:
    values.add(%sim.effectiveGate(NeighboursOf[pos][slot]))
  for offset in 0 ..< 4:
    if offset < sim.history.len:
      let past = sim.history[sim.history.len - 1 - offset].regions[pos]
      for value in [past.confirmed, past.confirmedNew, past.dead,
          past.gdp, int64(past.lockdown)]:
        values.add(%value)
    else:
      for field in 0 ..< 5:
        values.add(%0)
  %*{"decision_id": id, "values": values, "action_heads": [
    {"name": "lockdown", "choices": [0, 1, 2, 3, 4]},
    {"name": "testing", "choices": [0, 1, 2, 3]},
    {"name": "gate0", "choices": [-1, 0, 1, 2]},
    {"name": "gate1", "choices": [-1, 0, 1, 2]},
    {"name": "gate2", "choices": [-1, 0, 1, 2]}
  ]}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: contagion-train-bridge MANIFEST [standard|sprint]", 1)
  let variant = if args.len == 2: args[1] else: "standard"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var actions: array[Seats, JsonNode]
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      runtimeConfig["tokens"] = newJArray()
      for slot in 0 ..< Seats:
        runtimeConfig["tokens"].add(%("t" & $slot))
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      seat = 0
      id = 0
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.done
      response = game.encoding(seat, id, variant)
    of "teacher":
      doAssert not game.done
      let teacher = scriptedDecision(game, seat,
        if seat mod 2 == 0: skSentinel else: skLaggard)
      response = %*{"response": $(%*{
        "lockdown": teacher.lockdown, "testing": teacher.testing,
        "gate0": teacher.borders[0], "gate1": teacher.borders[1],
        "gate2": teacher.borders[2]})}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let chosen = parseJson(request["response"].getStr())
      actions[seat] = chosen
      inc id
      var observation: JsonNode
      if seat == Seats - 1:
        var decisions: array[Seats, Decision]
        for slot in 0 ..< Seats:
          let pos = game.posOf[slot]
          var borders = newJObject()
          for road in 0 ..< Degree:
            let far = otherEnd(NeighboursOf[pos][road], pos)
            let gate = actions[slot]["gate" & $road]
            if gate.getInt() >= 0:
              borders[RegionNames[far]] = gate
          decisions[slot] = parseDecision(game, slot, %*{
            "lockdown": actions[slot]["lockdown"],
            "testing": actions[slot]["testing"],
            "borders": borders, "aid": [], "say": "", "notes": ""})
          doAssert not decisions[slot].corrected
        for slot in 0 ..< Seats:
          game.applyDecision(slot, decisions[slot], false)
        if game.done:
          let outcome = game.resultsJson()
          var scores = newJObject()
          for slot in 0 ..< Seats:
            scores[$slot] = outcome["scores"][slot]
          observation = %*{"kind": "terminal", "scores": scores}
        else:
          seat = 0
          observation = game.decision(seat, id)
      else:
        inc seat
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": chosen,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
