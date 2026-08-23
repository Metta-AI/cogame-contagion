## Claude-backed decision making for Contagion. Each seat's policy is just a
## prompt: the game server composes the governor's view (its region, the
## reported case numbers everywhere, the published dials, the aid ledger, the
## table's talk, its own history and notes) plus that seat's prompt and asks
## Claude what it sets its dials to.
##
## Decisions within a week are SIMULTANEOUS by rule, so all six requests go
## out as ONE parallel batch (curly.makeRequests) — six round trips a week,
## not thirty-six. Invalid replies are retried once as a smaller batch with a
## hint, bounded by what is left of the week's budget, and anything still
## failing falls back to the `sentinel` scripted move.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes — this fallback is load-bearing.

import
  std/[json, math, os, strutils, times, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ScriptKind* = enum
    skNone = "none"
    skSentinel = "sentinel"
    skLaggard = "laggard"

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"sentinel" play the threshold
  ## dial policy, "laggard" the leaky neighbour, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "sentinel": skSentinel
  of "laggard", "leaky": skLaggard
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "contagion llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins
  ## a single id; without it, fall through this list — model access is a
  ## per-account Marketplace subscription, so an id that works in one account
  ## 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "contagion llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "contagion llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "contagion llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "contagion llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------
#
# Both baselines see ONLY what a seat sees — reported cases and published
# dials, never the true infection counts — are deterministic, are always
# legal, and never talk, take notes or send aid.

proc estimatedCases*(region: RegionState): int64 =
  ## A region's reported cases de-biased by its PUBLISHED testing level. Every
  ## governor can compute this for every region; that inference is intended
  ## play, not a leak.
  region.confirmed * Ppm div DetectPpm[region.testing]

proc estimatedRatePpm*(region: RegionState): int64 =
  let living = region.alive
  if living <= 0: 0 else: estimatedCases(region) * Ppm div living

const
  SentinelLockdownCutsPpm* = [1_000'i64, 4_000, 12_500, 30_000]
    ## Own de-biased prevalence, in ppm, at which the sentinel steps its
    ## lockdown 0->1, 1->2, 2->3, 3->4.
  SentinelTestingCutsPpm* = [1_000'i64, 12_500]
    ## ... and its testing 1->2, 2->3.
  SentinelRoadCutsPpm* = [160'i64, 800]
    ## A NEIGHBOUR's de-biased prevalence, in ppm, at which the sentinel
    ## screens (gate 1) and then closes (gate 2) the road to it.
    ##
    ## All three families are the argmax of the x0.25..x4 grid swept in
    ## tests/test_sweep.nim over five seeds; that test re-runs the sweep and
    ## fails if these stop being its best cell. They are NOT hand-picked.

proc sentinelDecision*(sim: Sim, seat: int): Decision =
  ## The threshold dial policy, and the universal fallback move.
  let pos = sim.posOf[seat]
  ## Once the variant is confirmed every threshold tightens by 20%, so the
  ## sentinel reacts one step earlier.
  let scale = if sim.variantActive(): 800_000'i64 else: Ppm
  let own = estimatedRatePpm(sim.regions[pos])
  result = blankDecision()
  result.lockdown =
    if own < SentinelLockdownCutsPpm[0] * scale div Ppm: 0
    elif own < SentinelLockdownCutsPpm[1] * scale div Ppm: 1
    elif own < SentinelLockdownCutsPpm[2] * scale div Ppm: 2
    elif own < SentinelLockdownCutsPpm[3] * scale div Ppm: 3
    else: 4
  result.testing =
    if own < SentinelTestingCutsPpm[0] * scale div Ppm: 1
    elif own < SentinelTestingCutsPpm[1] * scale div Ppm: 2
    else: 3
  for slot in 0 ..< Degree:
    let far = otherEnd(NeighboursOf[pos][slot], pos)
    let theirs = estimatedRatePpm(sim.regions[far])
    result.borders[slot] =
      if theirs < SentinelRoadCutsPpm[0] * scale div Ppm: 0
      elif theirs < SentinelRoadCutsPpm[1] * scale div Ppm: 1
      else: 2

proc laggardDecision*(sim: Sim, seat: int): Decision =
  ## The leaky neighbour: blind (testing 0, so it under-reports by 6.7x and
  ## never isolates), wide open, and late — lockdown 3 for three weeks once
  ## its own de-biased estimate first crosses 4%, then open again forever.
  let pos = sim.posOf[seat]
  result = blankDecision()
  result.lockdown = 0
  result.testing = 0
  result.borders = [0, 0, 0]
  var trigger = -1
  for week, record in sim.history:
    if estimatedRatePpm(record.regions[pos]) >= 40_000:
      trigger = week
      break
  if trigger >= 0 and sim.week >= trigger and sim.week < trigger + 3:
    result.lockdown = 3

proc scriptedDecision*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`. Always legal; never talks, notes or aids.
  case kind
  of skLaggard: laggardDecision(sim, seat)
  else: sentinelDecision(sim, seat)

# ---- Prompt building --------------------------------------------------------

proc ppmPercent(value: int64): string =
  ## A ppm rate as a readable percentage, two decimals.
  let hundredths = value * 100 div 10_000   # ppm -> hundredths of a percent
  $(hundredths div 100) & "." &
    align($(abs(hundredths) mod 100), 2, '0') & "%"

proc constantTables*(): string =
  """
CONSTANTS (public, identical for every region; all rates are exact):
  lockdown L:  0      1      2      3      4
    weekly transmission Beta   1.150  0.900  0.640  0.400  0.220
    output factor              1.00   0.92   0.80   0.62   0.40
  testing T:   0      1      2      3
    Beta multiplier            1.00   0.90   0.78   0.64
    DETECTION (share of true cases you can see)
                               0.15   0.35   0.65   0.90
    cost per week              0      20     55     110
  gate G:      0 open  1 screened  2 closed
    road pass-through          1.00   0.40        0.00
    your cost per road         0      10          30
    the far region's cost      0      5           15
  LEAK: every road, however tightly shut, still passes 0.12 of its traffic.
  Road mobility: main road 0.25, back road 0.15. Imported contacts infect at
    0.70 of local ones. One week's total force of infection is capped at 0.90.
  Each week 0.35 of the infectious resolve; 0.8% of those die when hospitals
    are under their 25,000-case capacity, up to 3.2% when 4x over.
  Output: 1000 credits a week for a fully open, fully healthy region, times
    the lockdown factor, times the share of the population still alive, minus
    1.5x prevalence of lost output (capped at 60%).
  SCORE = your region's accumulated GDP - 2 x your cumulative deaths."""

proc systemPrompt*(sim: Sim, seat: int): string =
  let pos = sim.posOf[seat]
  var neighbourText: seq[string]
  for slot in 0 ..< Degree:
    let edge = NeighboursOf[pos][slot]
    neighbourText.add(RegionNames[otherEnd(edge, pos)] & " (" &
      roadName(edge) & " road)")
  result = "You are the GOVERNOR of " & RegionNames[pos] &
    ", one of six regions on a road network fighting one epidemic for " &
    $sim.config.weeks & " weeks. Every region has 1,000,000 people and is " &
    "structurally identical; what differs is where the outbreak started and " &
    "what the other five governors do.\n\n" &
    "YOUR ROADS, in this exact order: " & neighbourText.join(", ") & ".\n\n" &
    """RULES
- Every week you set three dials at once: lockdown 0..4, testing 0..3, and one
  gate 0..2 per road. All six governors decide simultaneously; nobody sees
  anyone else's week before submitting. A road's EFFECTIVE gate is the TIGHTER
  of its two ends, and a road you shut costs the region at the far end money
  too.
- The infection then crosses every road whether or not it was closed: a fully
  sealed road still passes 12% of its traffic. Closure buys time, never safety.
- You never see the TRUE case counts, not even your own. You see REPORTED
  cases, which are your detection rate times the truth. Divide any region's
  reported number by the detection rate for ITS published testing level to
  estimate the truth: 400 reported at testing 0 is about 2,700 real.
- You may wire AID to other regions: at most 3 transfers and 200 credits a
  week, never more than your ledger holds. Aid settles immediately and
  unconditionally — there is no escrow and no way to bind anyone to a promise.
- Deaths are permanent, cost you 2 credits each, and shrink your workforce.
  Hospitals over capacity triple your death rate.
- A hidden VARIANT raises every transmission rate by 25% partway through.

""" & constantTables() & "\n\n" &
    (if sim.config.talk:
      "- You may SAY one short message (max " & $MaxSayLen & " characters) " &
      "each week. It is read by ALL SIX governors, one week late, and it is " &
      "not binding and may or may not be honest.\n"
     else: "") &
    "- Your notes are private to you and fed back to you every week.\n" &
    """
OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc historyTable(sim: Sim, pos: int): string =
  var lines: seq[string]
  lines.add("week | reported cases | new reported | deaths | L | T | gates | " &
    "gross | spend | net | ledger")
  for week, record in sim.history:
    let region = record.regions[pos]
    lines.add($week & " | " & $region.confirmed & " | " &
      $region.confirmedNew & " | " & $region.deathsWeek & " | " &
      $region.lockdown & " | " & $region.testing & " | " &
      $region.gates[0] & $region.gates[1] & $region.gates[2] & " | " &
      $region.grossGdp & " | " & $region.spendWeek & " | " &
      $(region.grossGdp - region.spendWeek) & " | " & $region.gdp)
  lines.join("\n")

proc tableBlock(sim: Sim, pos: int): string =
  var lines: seq[string]
  lines.add("region | reported cases | new | deaths | ledger | score | L | " &
    "T | gates (by that region's own roads)")
  for other in 0 ..< Regions:
    var gates: string
    for slot in 0 ..< Degree:
      gates.add($sim.regions[other].gates[slot])
    lines.add(RegionNames[other] & (if other == pos: " (YOU)" else: "") &
      " | " & $sim.regions[other].confirmed &
      " | " & $sim.regions[other].confirmedNew &
      " | " & $sim.regions[other].dead &
      " | " & $sim.regions[other].gdp &
      " | " & $sim.score(sim.seatOf[other]) &
      " | " & $sim.regions[other].lockdown &
      " | " & $sim.regions[other].testing &
      " | " & gates)
  lines.join("\n")

proc aidBlock(sim: Sim): string =
  var lines: seq[string]
  for transfer in sim.transfersOfWeek(sim.weeksPlayed - 1):
    lines.add(RegionNames[transfer.fromPos] & " -> " &
      RegionNames[transfer.toPos] & ": " & $transfer.amount)
  let totals = sim.aidTotals()
  var cumulative: seq[string]
  for other in 0 ..< Regions:
    if totals.sent[other] > 0 or totals.received[other] > 0:
      cumulative.add(RegionNames[other] & " sent " & $totals.sent[other] &
        ", received " & $totals.received[other])
  result = "PUBLIC AID LEDGER — settled last week:\n" &
    (if lines.len > 0: lines.join("\n") else: "(nothing)") & "\n" &
    "cumulative: " &
    (if cumulative.len > 0: cumulative.join("; ") else: "(nothing yet)") &
    "\n\n"

proc heardBlock(sim: Sim): string =
  if not sim.config.talk:
    return ""
  var lines: seq[string]
  for other in 0 ..< Regions:
    if sim.heard[other].len > 0:
      lines.add(RegionNames[other] & " said: \"" & sim.heard[other] & "\"")
  "WHAT THE TABLE SAID LAST WEEK:\n" &
    (if lines.len > 0: lines.join("\n") else: "(nobody spoke)") & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let pos = sim.posOf[seat]
  let mine = sim.regions[pos]
  var spendOwn = 0'i64
  var spendNeighbour = 0'i64
  var roads: seq[string]
  for slot in 0 ..< Degree:
    let edge = NeighboursOf[pos][slot]
    let far = otherEnd(edge, pos)
    spendOwn += BorderOwnCost[mine.gates[slot]]
    spendNeighbour +=
      BorderNeighbourCost[sim.regions[far].gates[slotOf(far, edge)]]
    roads.add(RegionNames[far] & " (" & roadName(edge) & "): your gate " &
      $mine.gates[slot] & ", effective " & $sim.effectiveGate(edge))
  result.add("Week " & $sim.week & " of " & $sim.config.weeks & ". You are " &
    RegionNames[pos] & ".\n\n")
  result.add("YOUR REGION: reported cases " & $mine.confirmed &
    " (new " & $mine.confirmedNew & "), deaths " & $mine.dead &
    " (" & $mine.deathsWeek & " last week), hospitals " &
    hospitalBandName(mine.hospital) & ". Ledger " & $mine.gdp &
    " (gross " & $mine.grossGdp & ", spend " & $mine.spendWeek &
    " = testing " & $TestCost[mine.testing] & " + your borders " &
    $spendOwn & " + neighbours' borders " & $spendNeighbour & ")." &
    " Aid in " & $mine.aidIn & ", out " & $mine.aidOut &
    ". Score " & $sim.score(seat) & ".\n")
  result.add("YOUR DIALS NOW: lockdown " & $mine.lockdown & ", testing " &
    $mine.testing & ". Roads: " & roads.join("; ") & ".\n")
  result.add("Your reported cases de-bias to about " &
    $estimatedCases(mine) & " true cases (" &
    ppmPercent(estimatedRatePpm(mine)) & " of your people).\n\n")
  result.add("THE TABLE:\n" & tableBlock(sim, pos) & "\n\n")
  result.add(sim.aidBlock())
  result.add(sim.heardBlock())
  result.add("YOUR HISTORY:\n" & historyTable(sim, pos) & "\n\n")
  if sim.variantActive():
    result.add("THE VARIANT IS LOOSE: every transmission rate is 25% higher " &
      "than the table above.\n\n")
  result.add("YOUR NOTES FROM EARLIER WEEKS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  var borderExample: seq[string]
  for slot in 0 ..< Degree:
    borderExample.add("\"" &
      RegionNames[otherEnd(NeighboursOf[pos][slot], pos)] & "\": 0")
  result.add("Reply with ONLY {\"lockdown\": 0-4, \"testing\": 0-3, " &
    "\"borders\": {" & borderExample.join(", ") & "}, " &
    "\"aid\": [{\"to\": \"<region>\", \"amount\": <credits>}]" &
    (if sim.config.talk: ", \"say\": \"…\"" else: "") &
    ", \"notes\": \"…\"} — borders names only your own three roads and any " &
    "road you leave out keeps its current gate; aid is at most " &
    $MaxAidEntries & " transfers totalling " & $MaxAidPerWeek &
    " credits and never more than your ledger" &
    (if sim.config.talk: "; say at most " & $MaxSayLen & " characters (or \"\")"
     else: "") &
    "; notes at most " & $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A byte
  ## slice through a multi-byte character would leave invalid UTF-8 in the
  ## replay and break its JSON.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(ContagionError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a ContagionError describing why there
  ## is none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(ContagionError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = cleanText(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(ContagionError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(ContagionError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = cleanText(response.body, 300)
    discard client.tryNextBedrockModel("throttled")
    raise newException(ContagionError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(ContagionError, "anthropic error " & $response.code &
      ": " & cleanText(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(ContagionError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(ContagionError, "reply cut off at max_tokens before " &
      "any JSON: " & cleanText(result, 160).replace("\n", " "))

proc coerceDial(node: JsonNode, name: string, lo, hi: int): int =
  ## An int, a numeric string, or a float (rounded). Out of range or
  ## unparseable is HARD-INVALID.
  if node.isNil or node.kind == JNull:
    raise newException(ContagionError, "no " & name & " in response")
  var value = -1
  case node.kind
  of JInt:
    value = node.getInt()
  of JFloat:
    value = int(round(node.getFloat()))
  of JString:
    let text = node.getStr().strip()
    try:
      value = int(round(parseFloat(text)))
    except ValueError:
      raise newException(ContagionError, name & " is not a number: " & text)
  else:
    raise newException(ContagionError, name & " must be a number: " & $node)
  if value < lo or value > hi:
    raise newException(ContagionError,
      name & " must be " & $lo & ".." & $hi & ": " & $value)
  value

proc parseDecision*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Tolerant by design. HARD-INVALID (raises, so the seat is retried once and
  ## then falls back): a missing or out-of-range lockdown or testing, a
  ## `borders` that is not an object, an `aid` that is not an array. SOFT
  ## CORRECTIONS (applied and marked `corrected`): an unknown road, a gate
  ## outside 0..2, a self or unknown aid recipient, a bad amount, entries past
  ## the third.
  let pos = sim.posOf[seat]
  result = blankDecision()
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"say"}.getStr(), MaxSayLen).replace("\n", " ")
  result.lockdown = coerceDial(payload{"lockdown"}, "lockdown", 0, 4)
  result.testing = coerceDial(payload{"testing"}, "testing", 0, 3)

  let borders = payload{"borders"}
  if not (borders.isNil or borders.kind == JNull):
    if borders.kind != JObject:
      raise newException(ContagionError, "borders must be a JSON object")
    var named = 0
    for key, value in borders:
      let far = positionOfName(key)
      var slot = -1
      if far >= 0:
        for candidate in 0 ..< Degree:
          if otherEnd(NeighboursOf[pos][candidate], pos) == far:
            slot = candidate
      if slot < 0:
        ## Not one of this region's three roads: ignored, not fatal.
        result.corrected = true
        continue
      inc named
      if named > Degree:
        result.corrected = true
        continue
      var gate = 0
      try:
        gate = coerceDial(value, "gate", -1_000_000, 1_000_000)
      except ContagionError:
        result.corrected = true
        continue
      if gate < 0:
        gate = 0
        result.corrected = true
      elif gate > 2:
        gate = 2
        result.corrected = true
      result.borders[slot] = gate

  let aid = payload{"aid"}
  if not (aid.isNil or aid.kind == JNull):
    if aid.kind != JArray:
      raise newException(ContagionError, "aid must be a JSON array")
    for entry in aid:
      if result.aid.len >= MaxAidEntries:
        result.corrected = true
        break
      if entry.kind != JObject:
        result.corrected = true
        continue
      var name = entry{"to"}.getStr()
      if name.runeLen > 24:
        name = name.runeSubStr(0, 24)
      let far = positionOfName(name)
      if far < 0 or far == pos:
        result.corrected = true
        continue
      let amountNode = entry{"amount"}
      var amount = 0'i64
      if amountNode.isNil or amountNode.kind == JNull:
        result.corrected = true
        continue
      case amountNode.kind
      of JInt:
        amount = amountNode.getBiggestInt()
      of JFloat:
        amount = int64(round(amountNode.getFloat()))
      of JString:
        try:
          amount = int64(round(parseFloat(amountNode.getStr().strip())))
        except ValueError:
          result.corrected = true
          continue
      else:
        result.corrected = true
        continue
      if amount < 0:
        result.corrected = true
        continue
      if amount == 0:
        continue
      result.aid.add(AidEntry(to: far, amount: amount))

# ---- The weekly batch -------------------------------------------------------

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  budgetSeconds: int = 35
): tuple[decisions: seq[Decision], scripted: seq[bool]] =
  ## One decision per seat in `seats`, in order, each paired with whether it is
  ## a SCRIPTED move rather than a model reply. Never raises: any failure falls
  ## back to the scripted sentinel move so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  ##
  ## `result.scripted[i]` is true for a seat registered as a baseline, for
  ## every seat when the client has no credentials, AND for a seat that
  ## exhausted its retry and took the sentinel fallback — the caller cannot
  ## tell the last case from the registration, so this batch has to say so or
  ## the fallback never reaches the replay.
  ##
  ## The whole week goes out as ONE parallel batch, and the single retry is
  ## bounded by what is LEFT of the week's budget rather than by a second full
  ## timeout — that is what keeps the per-week ceiling a real ceiling.
  result.decisions = newSeq[Decision](seats.len)
  result.scripted = newSeq[bool](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result.decisions[index] = scriptedDecision(sim, seat,
        (if kind == skNone: skSentinel else: kind))
      result.scripted[index] = true
    else:
      open.add(index)
  let started = epochTime()
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var timeout = client.timeoutSeconds
    if attempt > 0:
      let remaining = int(float(budgetSeconds) - (epochTime() - started))
      timeout = max(5, min(10, remaining))
    else:
      ## Never longer than the week it belongs to: llmTimeoutSeconds is
      ## schema-permitted up to 300 while turnBudgetSeconds maxes at 120, so
      ## an unclamped first batch could outrun the whole week's budget and
      ## leave the between-weeks deadline check as the only backstop.
      timeout = max(5, min(timeout, budgetSeconds))
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, timeout)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let decision = parseDecision(sim, seat, extractJsonObject(text))
        ## Reject illegal replies here so the retry carries the hint.
        var probe = sim
        probe.applyDecision(seat, decision, false)
        result.decisions[index] = decision
      except CatchableError as error:
        echo "contagion llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "contagion llm: seat ", seat, " falling back to the sentinel move"
    result.decisions[index] = scriptedDecision(sim, seat, skSentinel)
    result.scripted[index] = true
