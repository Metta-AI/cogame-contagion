## Production text decisions queued against a frozen weekly governor view.
import std/[json, os]
import contagion/[player_policy, prompts, rules, sim]

const OperatorPrompt =
  "Protect your region's health and economy using the published case reports."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: Sim, seat, id: int, selection: PromptSelection): JsonNode =
  var view = game.playerViewJson(seat)
  let (system, user) = promptsFromView(view, OperatorPrompt, selection)
  view["prompt_template"] = selection.promptMetadata(system, user)
  var neighbours = newJArray()
  let pos = game.posOf[seat]
  for road in 0 ..< Degree:
    neighbours.add(%RegionNames[otherEnd(NeighboursOf[pos][road], pos)])
  %*{"kind": "decision", "game": "contagion", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.week,
    "inference_mode": "text_action", "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    "speech_messages": [], "typed_question": newJNull(),
    "action_schema": {"type": "object", "required": ["lockdown", "testing"],
      "properties": {
        "lockdown": {"type": "integer", "minimum": 0, "maximum": 4},
        "testing": {"type": "integer", "minimum": 0, "maximum": 3},
        "borders": {"type": "object", "propertyNames": {"enum": neighbours},
          "additionalProperties": {"type": "integer", "minimum": 0, "maximum": 2}},
        "aid": {"type": "array", "maxItems": 3, "items": {"type": "object",
          "required": ["to", "amount"], "properties": {
            "to": {"type": "string"}, "amount": {"type": "integer", "minimum": 0, "maximum": 200}}}},
        "say": {"type": "string", "maxLength": 160},
        "notes": {"type": "string", "maxLength": 700}}}}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: contagion-text-bridge MANIFEST standard|sprint", 1)
  let manifest = parseFile(args[0])
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == args[1]:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  var game: Sim
  var selection: PromptSelection
  var queued: array[Seats, Decision]
  var seat, id: int
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      selection = promptSelection(request)
      let split = if request.hasKey("split"): request["split"].getStr() else: "train"
      if split notin ["train", "validation", "test"]:
        raise newException(ValueError, "split must be train, validation, or test")
      if split == "train" and selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        raise newException(ValueError, "held-out wording is evaluation-only")
      var config = defaultGameConfig()
      let raw = copy(variantConfig)
      raw["seed"] = %seedOf(request["seed"].getStr())
      raw["tokens"] = newJArray()
      for slot in 0 ..< Seats:
        raw["tokens"].add(%("t" & $slot))
      config.update($raw)
      config = sampleEpisode(config)
      game = initSim(config)
      seat = 0
      id = 0
      response = game.decision(seat, id, selection)
    of "teacher":
      let teacher = scriptedDecision(game, seat,
        if seat mod 2 == 0: skSentinel else: skLaggard)
      response = %*{"response": $decisionJson(game, seat, teacher)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let parsed = parseDecision(game, seat, parseJson(request["response"].getStr()))
      let executed = decisionJson(game, seat, parsed)
      queued[seat] = parsed
      inc id
      inc seat
      if seat == Seats:
        for slot in 0 ..< Seats:
          game.applyDecision(slot, queued[slot], false)
        seat = 0
      var observation: JsonNode
      if game.done:
        let outcome = game.resultsJson()
        var scores = newJObject()
        for slot in 0 ..< Seats:
          scores[$slot] = outcome["scores"][slot]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(seat, id, selection)
      response = %*{"kind": "accepted", "action": executed, "observation": observation}
    else:
      raise newException(ValueError, "unknown bridge command")
    stdout.writeLine($response)
    stdout.flushFile()
