## Export complete Contagion games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import contagion/[llm, sim]

const OperatorPrompt = "Protect your region's health and economy using the published case reports."
const Variants = ["standard", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    runtimeConfig["turnDelayMs"] = %0
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      let pending = sim.pendingSeats()
      var decisions: seq[tuple[seat: int, decision: Decision]]
      for seat in pending:
        let teacher = scriptedDecision(sim, seat,
          if seat mod 2 == 0: skSentinel else: skLaggard)
        let pos = sim.posOf[seat]
        var borders = newJObject()
        for slot in 0 ..< Degree:
          let neighbour = otherEnd(NeighboursOf[pos][slot], pos)
          borders[RegionNames[neighbour]] = %teacher.borders[slot]
        let completion = %*{
          "lockdown": teacher.lockdown,
          "testing": teacher.testing,
          "borders": borders,
          "aid": [],
          "say": teacher.say,
          "notes": teacher.notes
        }
        let parsed = parseDecision(sim, seat, completion)
        doAssert parsed.lockdown == teacher.lockdown and
          parsed.testing == teacher.testing and
          parsed.borders == teacher.borders and
          parsed.aid.len == 0 and not parsed.corrected
        rows.add($(%*{
          "episode_id": "contagion-" & variant & "-" & $seed,
          "seed": "contagion-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, seat)},
            {"role": "user", "content": userPrompt(sim, seat,
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "contagion",
          "action_schema_revision": "contagion-dials-v1"
        }))
        decisions.add((seat, parsed))
      for item in decisions:
        sim.applyDecision(item.seat, item.decision, true)
    doAssert sim.reason == "complete" and sim.weeksPlayed == config.weeks
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "weeks_played": sim.weeksPlayed})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "contagion",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-sentinel-and-laggard",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
