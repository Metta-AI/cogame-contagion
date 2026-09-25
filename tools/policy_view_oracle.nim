## Emits private views and native baseline actions across complete games.
import std/json
import contagion/[player_policy, rules, sim]

for seed in [1, 7, 42, 1234]:
  var config = defaultGameConfig()
  config.seed = seed
  config.sampled = true
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "P" & $seat))
  var game = initSim(config)
  while not game.done:
    let snapshot = game
    for seat in snapshot.pendingSeats():
      let sentinel = scriptedDecision(snapshot, seat, skSentinel)
      let laggard = scriptedDecision(snapshot, seat, skLaggard)
      let (system, user) = promptsFromView(snapshot.playerViewJson(seat),
        "operator says hi")
      echo $(%*{
        "view": snapshot.playerViewJson(seat),
        "sentinel": decisionJson(snapshot, seat, sentinel),
        "laggard": decisionJson(snapshot, seat, laggard),
        "system": system, "user": user
      })
      game.applyDecision(seat,
        if seat mod 2 == 0: sentinel else: laggard, true)
