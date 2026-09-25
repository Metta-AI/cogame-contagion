## Contagion model, prompt, and scripted player policy from private views.

import std/[json, os, strutils, unicode]
import bitworld/runtime, curly
import sim, rules

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
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

proc newLlmClient*(model: string, maxOutputTokens, timeoutSeconds: int): LlmClient =
  result = LlmClient(
    model: model,
    maxOutputTokens: maxOutputTokens,
    timeoutSeconds: timeoutSeconds
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

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  headers["X-Coworld-Player-Slot"] = $slot
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

proc estimatedRate(view: JsonNode): int64 =
  let living = Pop - view["deaths"].getBiggestInt()
  if living <= 0:
    return 0
  let detected = DetectPpm[view["testing"].getInt()]
  view["confirmed"].getBiggestInt() * Ppm div detected * Ppm div living

proc scriptedActionFromView*(view: JsonNode, kind: ScriptKind): JsonNode =
  ## A player baseline uses only its private observation. The game retains
  ## the same sentinel calculation solely for missing or invalid actions.
  let own = view["own"]
  var borders = newJObject()
  let scale = if view["variant"].getBool(): 800_000'i64 else: Ppm
  if kind == skLaggard:
    var trigger = -1
    for row in view["history"]:
      let living = Pop - row["deaths"].getBiggestInt()
      let rate =
        if living <= 0: 0'i64
        else: row["confirmed"].getBiggestInt() * Ppm div
          DetectPpm[row["testing"].getInt()] * Ppm div living
      if rate >= 40_000 and trigger < 0:
        trigger = row["week"].getInt()
    for gate in own["gates"]:
      borders[gate["to"].getStr()] = %0
    let week = view["week"].getInt()
    return %*{
      "lockdown": (if trigger >= 0 and week >= trigger and week < trigger + 3:
        3 else: 0),
      "testing": 0, "borders": borders, "aid": [],
      "say": "", "notes": ""
    }
  let ownRate = estimatedRate(own)
  let lockdown =
    if ownRate < SentinelLockdownCutsPpm[0] * scale div Ppm: 0
    elif ownRate < SentinelLockdownCutsPpm[1] * scale div Ppm: 1
    elif ownRate < SentinelLockdownCutsPpm[2] * scale div Ppm: 2
    elif ownRate < SentinelLockdownCutsPpm[3] * scale div Ppm: 3
    else: 4
  let testing =
    if ownRate < SentinelTestingCutsPpm[0] * scale div Ppm: 1
    elif ownRate < SentinelTestingCutsPpm[1] * scale div Ppm: 2
    else: 3
  for gate in own["gates"]:
    let neighbour = gate["to"].getStr()
    var rate = 0'i64
    for other in view["others"]:
      if other["region"].getStr() == neighbour:
        rate = estimatedRate(other)
        break
    borders[neighbour] =
      %(if rate < SentinelRoadCutsPpm[0] * scale div Ppm: 0
        elif rate < SentinelRoadCutsPpm[1] * scale div Ppm: 1
        else: 2)
  %*{"lockdown": lockdown, "testing": testing, "borders": borders,
     "aid": [], "say": "", "notes": ""}

proc promptsFromView*(view: JsonNode, guidance: string): tuple[system, user: string] =
  result.system = "You are the governor of " & view["region"].getStr() &
    " in Contagion. Six governors set lockdown 0..4, testing 0..3, and " &
    "three road gates 0..2 simultaneously each week. You may send up to " &
    "200 credits of aid and a short public message. True infection counts " &
    "are hidden; reported cases reflect each region's published testing. " &
    "Maximize your own ledger minus twice your deaths. Reply with one JSON " &
    "action and no other text."
  result.user = "Private governor observation:\n" & $view &
    "\nOperator guidance:\n" & guidance &
    "\nReply with only {\"lockdown\": 0, \"testing\": 2, " &
    "\"borders\": {\"neighbour\": 0}, \"aid\": [], " &
    "\"say\": \"\", \"notes\": \"\"}. Only name your three roads."

proc choosePromptAction*(client: LlmClient, view: JsonNode,
    guidance: string, slot: int): JsonNode =
  let (system, user) = promptsFromView(view, guidance)
  let request = client.requestFor(system, user, slot)
  var batch: RequestBatch
  batch.post(request.url, request.headers, request.body, "seat")
  let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
  let reply = client.textOf(responses[0].response,
    responses[0].error, request.url)
  let first = reply.find('{')
  let last = reply.rfind('}')
  if first < 0 or last <= first:
    raise newException(ContagionError, "no JSON action in response")
  parseJson(reply[first .. last])
