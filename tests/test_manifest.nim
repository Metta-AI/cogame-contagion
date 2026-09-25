## Packaging invariants. The manifest is what the platform schedules episodes
## from, and half of its numbers have to agree with the rules in src/ and with
## the seat count in tools/ci/docker_smoke.sh. A test is the only thing that
## keeps them agreeing after an edit to one of them.

import std/[json, os, sets, strutils, unittest]
import support/helpers

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc readRepoFile(relative: string): string =
  let path = repoRoot() / relative
  check fileExists(path)
  readFile(path)

let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))

suite "the manifest":
  test "the replay viewer is the static bundle, never a pod":
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    ## And nothing anywhere declares a live /client/replay viewer.
    check "client/replay" notin
      manifest["game"]["replay_viewer"].pretty()

  test "num_agents is six in every variant and in the cert fixture":
    check manifest["variants"].len >= 1
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == Seats
      check variant["game_config"]["players"].len == Seats
      check variant.hasKey("description")
      check variant["description"].getStr().len > 0
    check manifest["certification"]["game_config"]["num_agents"].getInt() ==
      Seats
    check manifest["certification"]["game_config"]["players"].len == Seats
    check manifest["certification"]["players"].len == Seats

  test "the config schema pins the seat count at six in both places":
    let properties = manifest["game"]["config_schema"]["properties"]
    for key in ["tokens", "players"]:
      check properties[key]["minItems"].getInt() == Seats
      check properties[key]["maxItems"].getInt() == Seats
    check properties["num_agents"]["minimum"].getInt() == Seats
    check properties["num_agents"]["maximum"].getInt() == Seats
    check manifest["game"]["config_schema"]["additionalProperties"].getBool() ==
      false
    var required: seq[string]
    for entry in manifest["game"]["config_schema"]["required"]:
      required.add(entry.getStr())
    check "tokens" in required
    check "players" in required
    ## Every key the game actually reads has to be declarable.
    for key in ["seed", "weeks", "talk", "episodeTimeoutSeconds",
        "turnBudgetSeconds", "turnDelayMs",
        "player_connect_timeout_seconds"]:
      check properties.hasKey(key)
    check properties["weeks"]["minimum"].getInt() == MinWeeks
    check properties["weeks"]["maximum"].getInt() == MaxWeeks

  test "the results schema is the closed key set the sim writes":
    let schema = manifest["game"]["results_schema"]
    var declared = initHashSet[string]()
    for key in schema["properties"].keys:
      declared.incl(key)
    var written = initHashSet[string]()
    let sim = initSim(fixtureConfig(weeks = 4, seed = 3))
    for key in sim.resultsJson().keys:
      written.incl(key)
    check declared == written
    var required = initHashSet[string]()
    for entry in schema["required"]:
      required.incl(entry.getStr())
    check required == written
    check schema["additionalProperties"].getBool() == false
    for key in ["names", "scores", "gdp", "deaths", "regions"]:
      check schema["properties"][key]["minItems"].getInt() == Seats
      check schema["properties"][key]["maxItems"].getInt() == Seats
    ## Score is GDP minus a death penalty, so it has no ceiling of zero.
    check not schema["properties"]["scores"]["items"].hasKey("maximum")
    var reasons: seq[string]
    for entry in schema["properties"]["reason"]["enum"]:
      reasons.add(entry.getStr())
    check reasons == @["complete", "deadline"]

  test "both protocols and all three docs are non-empty inline text":
    let protocols = manifest["game"]["protocols"]
    for key in ["player", "global"]:
      check protocols.hasKey(key)
      check protocols[key]["type"].getStr() == "text"
      check protocols[key]["value"].getStr().len > 200
    check "contagion.player.v3" in protocols["player"]["value"].getStr()
    check "/global" in protocols["global"]["value"].getStr()

    let docs = manifest["game"]["docs"]
    check docs["readme"]["type"].getStr() == "text"
    check docs["readme"]["value"].getStr().len > 200
    check docs["pages"].len == 2
    var pageIds: seq[string]
    for page in docs["pages"]:
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200
      pageIds.add(page["id"].getStr())
    check pageIds == @["rules.md", "protocol.md"]

  test "every certification slot names a declared player, and every declared player has a slot":
    var declared = initHashSet[string]()
    for player in manifest["player"]:
      check player["type"].getStr() == "player"
      check player["id"].getStr().len > 0
      check player["name"].getStr().len > 0
      check player["description"].getStr().len > 0
      check player["run"][0].getStr() == "/bin/contagion-player"
      check player["image"].getStr() == "{{CONTAGION_IMAGE}}"
      declared.incl(player["id"].getStr())
    var seated = initHashSet[string]()
    for slot in manifest["certification"]["players"]:
      let id = slot["player_id"].getStr()
      check id in declared
      seated.incl(id)
    ## `coworld certify`'s players-run check fails any declared player that
    ## never occupies a certification slot.
    check declared == seated

  test "the game runnable needs no inference credential":
    let runnable = manifest["game"]["runnable"]
    check runnable["type"].getStr() == "game"
    check runnable["image"].getStr() == "{{CONTAGION_IMAGE}}"
    check runnable["run"][0].getStr() == "/bin/contagion"
    check not runnable.hasKey("env")
    check manifest["player"][0]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/contagion/anthropic_api_key"
    check manifest["game"]["name"].getStr() == "contagion"
    check not manifest["game"].hasKey("version")
    check manifest["tags"].len >= 3

suite "the compose file and the smoke cross-check":
  test "the image placeholder is derived from the compose service name":
    let compose = readRepoFile("compose.yaml")
    check "contagion:" in compose
    check "coworld-contagion:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose

  test "SMOKE_SEATS agrees with the manifest fixture":
    let smoke = readRepoFile("tools/ci/docker_smoke.sh")
    check "SMOKE_SEATS:-" & $Seats in smoke.replace("{", "").replace("}", "")
    check "SMOKE_REQUIRE_REPLAY_JSON:-1" in
      smoke.replace("{", "").replace("}", "")

  test "the four policies are one image, env-switched, with two champions":
    let policies = parseJson(readRepoFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var owners: seq[string]
    for policy in policies:
      check policy["run"].getStr() == "/bin/contagion-player"
      check policy["name"].getStr().startsWith("contagion-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check parseScriptKind(policy["env"]["PLAYER_SCRIPTED"].getStr()) !=
          skNone
      if policy.hasKey("player"):
        owners.add(policy["player"].getStr())
    check prompts == 2
    check scripted == 2
    ## Champion #2 is uploaded while daveey-1 is the active player.
    check owners == @["ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"]
    check policies[1]["name"].getStr() == "contagion-broker"
    check policies[1].hasKey("player")
    ## Distinct prompts, or the two champions dedupe to one policy version.
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()

suite "the 360 px legibility guard":
  test "chrome.css keeps the plate-name rule and both media blocks":
    let css = readRepoFile("client/chrome.css")
    let flat = css.replace("\n", " ").replace("  ", " ")
    check ".plate-name" in css
    check "min-width: 3.2em" in css
    check "flex: 1 1 auto" in css
    check "@media (max-width: 640px)" in css
    check "@media (max-width: 420px)" in css
    ## Labels go under 640 px; the death chip stays, because it is the drama.
    let narrow = flat[flat.find("@media (max-width: 640px)") .. ^1]
    check ".plate-label { display: none; }" in narrow
    check ".plate-dead" in css
    ## Six plates at desktop width, three then two when embedded.
    check "repeat(6, 1fr)" in css
    check "repeat(3, 1fr)" in css
    check "repeat(2, 1fr)" in css
    ## The sixth seat colour exists; renderer.js has six.
    check ".seat5" in css
    check "--orange" in css

  test "the viewer bundle inventory in the build hook is complete":
    let hook = readRepoFile("tools/build_replay_viewer.sh")
    for asset in ["map_board.png", "region_tile.png", "shutter.png",
        "gate_arm.png", "aid_packet.png", "font.ttf",
        "governor_red_front.png", "governor_blue_front.png",
        "governor_green_front.png", "governor_yellow_front.png",
        "governor_violet_front.png", "governor_orange_front.png"]:
      check asset in hook
      check fileExists(repoRoot() / "data" / asset)
    check "contagion_replay.wasm" in hook
    check "contagion_replay.js" in hook
    check "index.html" in hook

  test "the emscripten export name and the shell's factory call are a pair":
    let flags = readRepoFile("replay-viewer/config.nims")
    let shell = readRepoFile("replay-viewer/static_replay.js")
    check "-s MODULARIZE=1" in flags
    check "-s EXPORT_NAME=ContagionReplayModule" in flags
    ## A MODULARIZE build exports a FACTORY; the shell must CALL it. Waiting
    ## on Module.onRuntimeInitialized instead hangs forever, silently.
    check "ContagionReplayModule()" in shell
    check "onRuntimeInitialized" notin shell
    for symbol in ["_cg_load_replay", "_cg_payload_ptr", "_cg_payload_len",
        "_cg_error_ptr", "_cg_error_len"]:
      check symbol in flags
      check symbol in shell
    ## The readiness signals the CI viewer smoke polls.
    check "data-replay-error" in shell
    check "data-replay-loaded" in readRepoFile("client/renderer.js")

  test "replay playback has a Space pause and a 0.5x speed chip":
    ## Both live in attachReplay + chrome.css, so the server page
    ## (client/replay.html) and the static wasm bundle
    ## (replay-viewer/index.html) get them from the same source.
    let js = readRepoFile("client/renderer.js")
    check "togglePlay" in js
    check "evt.code !== \"Space\"" in js
    check "[0.5, 1, 2]" in js
    ## The chips have to actually reach playback: the dwell is divided.
    check "stepMs / speed" in js
    check ".tchip" in readRepoFile("client/chrome.css")
    for page in ["client/replay.html", "replay-viewer/index.html"]:
      check "renderer.js" in readRepoFile(page)
