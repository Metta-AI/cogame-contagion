## Shared value types for Contagion: the runtime config, one region's
## compartments and dials, a governor's weekly decision, and the event
## record the replay is made of.
##
## Every quantity the rules touch is an INTEGER, and every people/credit
## quantity is `int64`. That is not decoration: the wasm replay viewer is
## compiled for `--cpu:wasm32`, where Nim's `int` is 32 bits, and the
## force-of-infection arithmetic reaches ~9e11. Declaring the state
## explicitly as int64 makes the browser's re-derivation bit-identical to
## the x86 server's instead of silently overflowing.

import std/[json, strutils]

const
  Seats* = 6
  Regions* = 6
  Degree* = 3          ## every region has exactly three incident roads
  Ppm* = 1_000_000'i64 ## one whole unit, in parts per million

type
  ContagionError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    weeks*: int           ## weeks of decisions in the episode
    talk*: bool           ## governors may address the table each week
    episodeTimeoutSeconds*: int ## assumed platform kill time when env is silent
    sampled*: bool        ## true once the pacing budget has been applied
    turnDelayMs*: int
    turnBudgetSeconds*: int ## hard wall-clock ceiling for one week
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  RegionState* = object
    ## One region as observed at the start of a week. `gates` is indexed by
    ## the region's own incident-edge order (`NeighboursOf[pos]`).
    susceptible*: int64
    infected*: int64
    recovered*: int64
    dead*: int64
    gdp*: int64            ## running ledger, may go negative
    lockdown*: int         ## 0..4
    testing*: int          ## 0..3
    gates*: array[Degree, int] ## 0..2, this region's own end of each road
    newInfections*: int64
    deathsWeek*: int64
    confirmed*: int64      ## reported prevalent cases (biased by testing)
    confirmedNew*: int64   ## reported new cases this week
    grossGdp*: int64
    spendWeek*: int64
    aidIn*: int64
    aidOut*: int64
    hospital*: int         ## band 0 normal .. 3 critical

  AidEntry* = object
    to*: int               ## recipient POSITION, 0..5
    amount*: int64

  Decision* = object
    ## What one governor submits for the observed week. `borders` is by the
    ## region's incident-edge order; -1 means "keep last week's gate", which
    ## is what a reply that simply does not mention a road produces.
    lockdown*: int
    testing*: int
    borders*: array[Degree, int]
    aid*: seq[AidEntry]
    say*: string
    notes*: string
    corrected*: bool       ## a soft correction was applied while parsing

  EventKind* = enum
    evStart = "start"
    evWeek = "week"
    evDial = "dial"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    week*: int             ## week/dial: the observed week; end: weeks played
    seat*: int             ## dial: the deciding seat; -1 otherwise
    pos*: int              ## dial: that seat's region position; -1 otherwise
    variant*: bool         ## week: the variant is loose
    regions*: seq[RegionState] ## week: all six, in POSITION order
    decision*: Decision    ## dial: the decision as latched
    scripted*: bool        ## dial: decided by a scripted baseline
    text*: string          ## dial: the seat's notes; end: the reason

proc blankDecision*(): Decision =
  Decision(lockdown: 0, testing: 0, borders: [-1, -1, -1])

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    weeks: 20,
    talk: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 300,
    turnBudgetSeconds: 35,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 25
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(ContagionError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("weeks"):
    config.weeks = node["weeks"].getInt()
  if node.hasKey("talk"):
    config.talk = node["talk"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("turnBudgetSeconds"):
    config.turnBudgetSeconds = node["turnBudgetSeconds"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.weeks < 4:
    raise newException(ContagionError, "weeks must be at least 4")
