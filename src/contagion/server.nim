## Contagion game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared map renderer
##   GET /client/chrome.css          - shared broadcast chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (contagion.player.v2), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":"<region alias>",...}
##                   {"type":"state",...} after every event, redacted to what
##                     a governor may see (reported cases, never the truth)
##                   {"type":"final","scores":[...],"gdp":[...],"deaths":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"sentinel"}
##                   (max 4000 chars; scripted plays a built-in baseline for
##                   that seat: "sentinel" / "1", or "laggard")
##                   {"type":"decision","week":N,"action":{...}}
##   game -> external player: {"type":"turn","week":N,"system":str,
##                            "user":str,"candidates":[...]}

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    external: seq[bool]
    pendingWeek: int
    pendingDecisions: Table[int, Decision]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under region aliases; the POLICY names ride alongside for the
  ## SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"contagion"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## The governor's view: everything the prompt sees and nothing more. The
  ## TRUE infection counts of every region, including this seat's own, are
  ## absent — a governor only ever sees reported cases.
  result = gs.sim.playerViewJson(slot)
  result["type"] = %"state"
  result["slot"] = %slot
  result["name"] = %gs.sim.regionOf(slot)
  result["started"] = %gs.started

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table (including the
  ## true infection counts); players get the redacted governor view.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## Self-sufficient: the seed re-derives the permutation, the outbreak
  ## position and the variant week; the config, both name spaces, every
  ## week's full state and the results are all in these bytes.
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "contagion.replay.v" & $ReplayVersion,
    "rules": RulesVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "weeks": gs.config.weeks,
      "seed": gs.config.seed,
      "talk": gs.config.talk,
      "sampled": true
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the region aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "gdp": results["gdp"],
      "deaths": results["deaths"],
      "regions": results["regions"],
      "names": aliasNames,
      "weeks": results["weeks"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "contagion: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  sleep(500)
  echo "contagion: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc pinUnconnectedSeats*(scripted: var seq[ScriptKind], connected: seq[bool]) =
  ## After `player_connect_timeout_seconds` the game starts with whoever is
  ## there, and a seat whose container never connected is treated as
  ## `PLAYER_SCRIPTED=sentinel`: there is nobody behind it to guide it, so
  ## sending its unguided prompt to the model would cost a round trip a week
  ## to play a worse policy than the baseline. A seat that already registered
  ## a baseline keeps it, and a late connect takes the seat back when its
  ## prompt frame lands.
  for slot in 0 ..< scripted.len:
    let up = slot < connected.len and connected[slot]
    if not up and scripted[slot] == skNone:
      scripted[slot] = skSentinel

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      var connected = newSeq[bool](config.players.len)
      for slot in 0 ..< connected.len:
        connected[slot] = state.playerSockets.hasKey(slot)
      pinUnconnectedSeats(state.scripted, connected)
      for slot in 0 ..< connected.len:
        if not connected[slot]:
          echo "contagion: slot ", slot, " never connected; playing ",
            state.scripted[slot]
      echo "contagion: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with room
    ## to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "contagion: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      var external: seq[bool]
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and epochTime() > playDeadline:
          ## The platform kills an episode that outruns its timeout and keeps
          ## nothing at all, so give up weeks rather than the whole result:
          ## stop here, BETWEEN weeks, so no half-resolved week can reach the
          ## replay.
          echo "contagion: episode deadline reached after ",
            state.sim.weeksPlayed, "/", config.weeks,
            " weeks; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        external = state.external
        echo "contagion: week ", state.sim.week, " of ", config.weeks,
          " at ", (epochTime() - gameStart).int, "s"

      let decisionDeadline = epochTime() + config.turnBudgetSeconds.float
      var modelSeats, waitingSeats: seq[int]
      withLock stateLock:
        state.pendingWeek = simCopy.week
        state.pendingDecisions.clear()
        for seat in seats:
          if not external[seat]:
            modelSeats.add(seat)
            continue
          if state.playerSockets.hasKey(seat):
            state.playerSockets[seat].send($ %*{
              "type": "turn",
              "week": simCopy.week,
              "system": systemPrompt(simCopy, seat),
              "user": userPrompt(simCopy, seat, prompts[seat]),
              "candidates": [
                {"id": "sentinel", "action": decisionJson(simCopy, seat,
                  scriptedDecision(simCopy, seat, skSentinel))},
                {"id": "laggard", "action": decisionJson(simCopy, seat,
                  scriptedDecision(simCopy, seat, skLaggard))}
              ]
            })
            waitingSeats.add(seat)
      let batch = client.decideAll(simCopy, modelSeats, prompts, scripted,
        config.turnBudgetSeconds)
      while waitingSeats.len > 0 and epochTime() < decisionDeadline:
        var received = 0
        withLock stateLock:
          for seat in waitingSeats:
            if state.pendingDecisions.hasKey(seat):
              received.inc
        if received == waitingSeats.len:
          break
        sleep(20)
      var decisions = newSeq[Decision](seats.len)
      var wasScripted = newSeq[bool](seats.len)
      var modelIndex = 0
      for index, seat in seats:
        if external[seat]:
          continue
        decisions[index] = batch.decisions[modelIndex]
        wasScripted[index] = batch.scripted[modelIndex]
        modelIndex.inc
      withLock stateLock:
        for index, seat in seats:
          if not external[seat]:
            continue
          if state.pendingDecisions.hasKey(seat):
            decisions[index] = state.pendingDecisions[seat]
          else:
            echo "contagion: external seat ", seat, " using sentinel fallback"
            decisions[index] = scriptedDecision(simCopy, seat, skSentinel)
            wasScripted[index] = true
        state.pendingWeek = -1

      withLock stateLock:
        for index, seat in seats:
          let decision = decisions[index]
          ## Straight from the batch, NOT re-derived from the registration: a
          ## seat that exhausted its retry and took the sentinel fallback is
          ## registered as an LLM policy but did not play one, and the replay
          ## is the only place phase 60 can count that.
          echo "contagion: week ", state.sim.week, " ",
            state.sim.regionOf(seat), " L", decision.lockdown,
            " T", decision.testing,
            " gates ", decision.borders[0], decision.borders[1],
            decision.borders[2],
            (if decision.aid.len > 0: " aid " & $decision.aid.len else: ""),
            (if decision.say.len > 0: " says \"" & decision.say & "\""
             else: ""),
            " at ", (epochTime() - gameStart).int, "s"
          try:
            state.sim.applyDecision(seat, decision, wasScripted[index])
          except ContagionError as error:
            echo "contagion: reply rejected (", error.msg,
              "); using the sentinel fallback"
            ## From the PRE-BATCH snapshot, not the live sim: lower-index
            ## seats have already latched this week, and the sentinel reads
            ## neighbours' published testing levels. Generating the fallback
            ## from the live sim would let it see a neighbour's week-w
            ## decision, which no governor may (design.md:156-157).
            let fallback = scriptedDecision(simCopy, seat, skSentinel)
            state.sim.applyDecision(seat, fallback, true)
            wasScripted[index] = true
        state.broadcastLocked()
        for index, seat in seats:
          if external[seat] and state.playerSockets.hasKey(seat):
            state.playerSockets[seat].send($ %*{
              "type": "decision_result", "week": simCopy.week,
              "accepted": not wasScripted[index]
            })

      ## Pace between weeks so spectators can read the map.
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    ## Let the last week land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "contagion: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      var neighbourNames = newJArray()
      for far in neighbours(state.sim.posOf[slot]):
        neighbourNames.add(%RegionNames[far])
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "contagion.player.v2",
        "slot": slot,
        "name": state.sim.regionOf(slot),
        "pos": state.sim.posOf[slot],
        "neighbours": neighbourNames,
        "weeks": state.config.weeks
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let scripted =
            if node.isNil: skNone
            elif node.kind == JBool: (if node.getBool(): skSentinel
              else: skNone)
            else: parseScriptKind(node.getStr())
          let external = payload{"external"}.getBool(false)
          if external and scripted != skNone:
            raise newException(ContagionError,
              "an external player cannot register as scripted")
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.external[slot] = external
          echo "contagion: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted != skNone: ", scripted " & $scripted
             elif external: ", external" else: ""), ")"
        elif payload{"type"}.getStr() == "decision":
          let week = payload["week"].getInt()
          let action = payload["action"]
          if action.kind != JObject:
            raise newException(ContagionError,
              "decision action must be an object")
          withLock stateLock:
            if state.external[slot] and week == state.pendingWeek and
                not state.pendingDecisions.hasKey(slot):
              let decision = parseDecision(state.sim, slot, action)
              var probe = state.sim
              probe.applyDecision(slot, decision, false)
              state.pendingDecisions[slot] = decision
      except CatchableError as error:
        echo "contagion: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.weeks = payload["config"]{"weeks"}.getInt(20)
  result.seed = payload["config"]{"seed"}.getInt(0)
  result.talk = payload["config"]{"talk"}.getBool(true)
  ## The replay carries the episode's fitted cap; never re-fit it. The
  ## permutation, the outbreak position and the variant week are re-derived
  ## from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states, and
  ## serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("contagion.replay.v1"),
    "rules": payload{"rules"}.getStr(RulesVersion),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "contagion: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(ContagionError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  state.external = newSeq[bool](config.players.len)
  state.pendingWeek = -1
  state.pendingDecisions = initTable[int, Decision]()
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "contagion: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
