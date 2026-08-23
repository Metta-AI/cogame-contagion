## Contagion player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a default
## outbreak strategy), then idles until the final frame. All of the actual
## decision making happens inside the game server, which sends this seat's
## prompt to Claude once a week, in one parallel batch with the other five.
##
## PLAYER_SCRIPTED=sentinel (or 1) registers the seat as the built-in
## threshold baseline instead; PLAYER_SCRIPTED=laggard as the leaky
## neighbour. The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <contagion-image> --name my-contagion \
##     --run /bin/contagion-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

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
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "contagion player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "contagion player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send merely queues — the
  ## game's quit(0) can outrun the flushed final frame. A dead socket is a
  ## normal end of episode, not a player failure, so the whole loop degrades
  ## to a clean exit 0.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "contagion player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "contagion player: seated at slot ",
            payload{"slot"}.getInt(), " as governor of ",
            payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "contagion player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "contagion player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "contagion player: socket ended (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
