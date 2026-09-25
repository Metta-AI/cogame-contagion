## Bundled Contagion prompt and scripted players. Every decision comes from
## the ordinary private view and is submitted through the player WebSocket.

import std/[json, options, os, strutils]
import whisky
import contagion/[rules, player_policy]

const DefaultPrompt = """
Suppress early and cheaply, then reopen. Every week convert your reported
cases into a true estimate by dividing by the detection rate for your CURRENT
testing level, and do the same for every other region using THEIR testing
level - a neighbour reporting 400 cases at testing 0 really has about 2700.
Buy information first: testing 2 is cheap and it both slows spread and stops
you flying blind. Raise lockdown one step before your estimated prevalence
doubles again, not after; hospitals overloaded means your deaths triple, and
deaths cost 2 credits each. Close a road only against a region whose estimated
prevalence is above 2%, and remember a closed road still leaks 12%, so closure
buys time, never safety. Reopen the moment your own estimate falls under 0.5% -
idle lockdown is pure loss. Say your real numbers out loud every week; a table
that trusts your figures will close its own roads against the actual hotspot
instead of against you. Send aid to whichever region is both hottest and
poorest: their outbreak is arriving at your door in two weeks whatever your
gates say, and 150 credits spent there is cheaper than a lockdown here.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = parseScriptKind(getEnv("PLAYER_SCRIPTED"))
  let client =
    if scripted != skNone: nil
    else: newLlmClient(
      getEnv("PLAYER_MODEL", "claude-sonnet-5"),
      parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900")),
      parseInt(getEnv("PLAYER_TIMEOUT_SECONDS", "25")))
  let socket = newWebSocket(url)
  var slot = -1
  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    let payload = parseJson(message.data)
    case payload{"type"}.getStr()
    of "welcome":
      slot = payload["slot"].getInt()
      echo "contagion player: seated at slot ", payload["slot"].getInt(),
        " as governor of ", payload["name"].getStr()
    of "turn":
      let view = payload["view"]
      let fallback = scripted != skNone or client.disabled
      let action =
        if fallback: scriptedActionFromView(view,
          (if scripted == skNone: skSentinel else: scripted))
        else: client.choosePromptAction(view, prompt, slot)
      socket.send($ %*{
        "type": "decision", "week": payload["week"],
        "source": (if fallback: "scripted" else: "player"),
        "action": action
      })
    of "decision_result":
      if not payload["accepted"].getBool():
        raise newException(ValueError, "game rejected player action")
    of "final":
      echo "contagion player: final scores ", payload["scores"]
      break
    else:
      discard
  socket.close()
