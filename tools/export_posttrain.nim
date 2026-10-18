## Export complete engine-resolved episodes as private candidate evidence.
import std/[json, options, os, osproc, strutils]
import bitworld/decision_trajectory
import contagion/[player_policy, prompts, rules, sim]

const OperatorPrompt = "Protect your region's health and economy using the published case reports."
const Variants = ["standard", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out prompt variants are evaluation-only")
  doAssert games >= 10 and firstSeed >= 1
  doAssert variant in Variants
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  var runs = newJArray()
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  try:
    for seed in firstSeed ..< firstSeed + games:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = newJArray()
      for seat in 0 ..< Seats:
        runtimeConfig["tokens"].add(%("t" & $seat))
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      var game = initSim(config)
      let family = "contagion-" & $seed
      let episodeId = family & "-" & variant & "-" &
        $selection.selectedVariant & "-" & $selection.seed
      let trajectory = newDecisionTrajectory(episodeId, family, "contagion",
        "source-" & revision, revision)
      var decisionId = 0
      while not game.done:
        let seats = game.pendingSeats()
        var decisions: array[Seats, Decision]
        var observations, replies, messages: array[Seats, JsonNode]
        for seat in seats:
          let teacher = scriptedDecision(game, seat,
            if seat mod 2 == 0: skSentinel else: skLaggard)
          replies[seat] = decisionJson(game, seat, teacher)
          decisions[seat] = parseDecision(game, seat, replies[seat])
          observations[seat] = game.playerViewJson(seat)
          let (system, user) = promptsFromView(observations[seat], OperatorPrompt, selection)
          observations[seat]["prompt_template"] = selection.promptMetadata(system, user)
          messages[seat] = %*[{"role": "system", "content": system},
            {"role": "user", "content": user}]
        let firstEvent = game.events.len
        for seat in seats:
          game.applyDecision(seat, decisions[seat], true)
        var recorded = 0
        for index in firstEvent ..< game.events.len:
          let event = game.events[index]
          if event.kind != evDial:
            continue
          let seat = event.seat
          let executed = decisionJson(game, seat, event.decision)
          var attempt = newDecisionAttempt($decisionId & "-teacher",
            if seat mod 2 == 0: "scripted-sentinel" else: "scripted-laggard", aoTeacher)
          attempt.prompt = messages[seat]
          attempt.parsedAction = replies[seat]
          attempt.response = %($replies[seat])
          attempt.accepted = replies[seat] == executed
          if not attempt.accepted:
            attempt.rejectionReason = some("engine-normalized-submission")
          trajectory.recordDecision($decisionId, $seat, observations[seat], @[attempt],
            if attempt.accepted: some(attempt.attemptId) else: none(string),
            executed, if attempt.accepted: asAccepted else: asFallback,
            game.done and recorded == seats.high,
            if attempt.accepted: none(string) else: some("engine-normalized-submission"))
          inc recorded
          inc decisionId
        doAssert recorded == seats.len
      doAssert game.reason == "complete" and game.weeksPlayed == config.weeks
      let results = game.resultsJson()
      var participants = newJObject()
      for seat in 0 ..< Seats:
        participants[$seat] = %*{"score": results["scores"][seat]}
      trajectory.finish(esCompleted, results, participants)
      stream.write(trajectory.eventsJsonl())
      runs.add(%*{"seed": seed, "decisions": decisionId,
        "scores": results["scores"], "weeks_played": game.weeksPlayed})
  finally:
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "contagion", "variant": variant,
    "source_revision": revision, "teacher": "scripted-sentinel-and-laggard",
    "operator_prompt": OperatorPrompt,
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs}) & "\n")
  echo "complete games=", games
