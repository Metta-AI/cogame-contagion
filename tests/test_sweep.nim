## The sentinel's dial thresholds are the game's calibration: they are the
## universal fallback move, the offline-certification policy and a fieldable
## baseline all at once, so "they look about right" is not good enough. This
## is the grid harness that settles them.
##
## It sweeps the two threshold families in `llm.nim` — the OWN-prevalence cuts
## that set lockdown and testing, and the NEIGHBOUR-prevalence cuts that set
## the gates — over a x0.25 .. x4 grid, five seeds a cell, six seats a seed,
## every episode played to its natural end. The shipped constants must be the
## grid's best cell. If someone edits `SentinelLockdownCutsPpm` and friends,
## this test re-runs the sweep and says whether the new numbers are still the
## argmax.
##
## The LAGGARD is deliberately NOT swept: it is the designed foil (blind, wide
## open, and three weeks late), and tuning it for score would delete the thing
## it exists to be.

import std/[sequtils, strutils, unittest]
import support/helpers

const
  Seeds = [1, 7, 42, 1234, 99]
  Weeks = 20
  Scales = [250_000'i64, 500_000, 1_000_000, 2_000_000, 4_000_000]
    ## Multiplier on a threshold family, in ppm: x0.25 (react four times
    ## earlier) through x4 (four times later). Ppm is what ships.

type Thresholds = object
  own: int64   ## scales SentinelLockdownCutsPpm and SentinelTestingCutsPpm
  road: int64  ## scales SentinelRoadCutsPpm

proc tunedDecision(sim: Sim, seat: int, t: Thresholds): Decision =
  ## `sentinelDecision` (llm.nim) with its two threshold families scaled. The
  ## CUTS come from the shipped constants, not from copied literals, so the
  ## only thing this can drift on is the branch structure — which the first
  ## test below pins decision-for-decision.
  let pos = sim.posOf[seat]
  let variant = if sim.variantActive(): 800_000'i64 else: Ppm
  proc cut(base, scale: int64): int64 =
    base * variant div Ppm * scale div Ppm
  let own = estimatedRatePpm(sim.regions[pos])
  result = blankDecision()
  result.lockdown =
    if own < cut(SentinelLockdownCutsPpm[0], t.own): 0
    elif own < cut(SentinelLockdownCutsPpm[1], t.own): 1
    elif own < cut(SentinelLockdownCutsPpm[2], t.own): 2
    elif own < cut(SentinelLockdownCutsPpm[3], t.own): 3
    else: 4
  result.testing =
    if own < cut(SentinelTestingCutsPpm[0], t.own): 1
    elif own < cut(SentinelTestingCutsPpm[1], t.own): 2
    else: 3
  for slot in 0 ..< Degree:
    let far = otherEnd(NeighboursOf[pos][slot], pos)
    let theirs = estimatedRatePpm(sim.regions[far])
    result.borders[slot] =
      if theirs < cut(SentinelRoadCutsPpm[0], t.road): 0
      elif theirs < cut(SentinelRoadCutsPpm[1], t.road): 1
      else: 2

proc playTuned(seed: int, t: Thresholds): tuple[score, deaths: int64] =
  ## One whole episode, all six seats on `t`. Each week's six decisions come
  ## from ONE snapshot taken before any of them latch, exactly as the server's
  ## per-week batch does — a sweep whose seats could see each other's
  ## current-week dials would be tuning a different game.
  var sim = initSim(fixtureConfig(weeks = Weeks, seed = seed))
  while not sim.done:
    let view = sim
    for seat in view.pendingSeats():
      sim.applyDecision(seat, tunedDecision(view, seat, t), true)
  check sim.reason == "complete"
  for seat in 0 ..< Seats:
    result.score += sim.score(seat)
    result.deaths += sim.regions[sim.posOf[seat]].dead
  result.score = result.score div Seats

proc sweep(t: Thresholds): tuple[score, deaths: int64] =
  ## Mean over the seeds: one seed's outbreak position and variant week can
  ## flatter one threshold set, so no cell is decided on one episode.
  for seed in Seeds:
    let one = playTuned(seed, t)
    result.score += one.score
    result.deaths += one.deaths
  result.score = result.score div Seeds.len
  result.deaths = result.deaths div Seeds.len

suite "sentinel threshold sweep":
  test "the harness policy IS the shipped sentinel at the shipped scales":
    ## Every seat, every week, every seed — not a spot check.
    let shipped = Thresholds(own: Ppm, road: Ppm)
    for seed in Seeds:
      var sim = initSim(fixtureConfig(weeks = Weeks, seed = seed))
      while not sim.done:
        let view = sim
        for seat in view.pendingSeats():
          let mine = tunedDecision(view, seat, shipped)
          check mine == scriptedDecision(view, seat, skSentinel)
          sim.applyDecision(seat, mine, true)

  test "the shipped thresholds are the sweep's best cell":
    var bestOwn = 0'i64
    var bestRoad = 0'i64
    var bestScore = low(int64)
    var shippedScore = low(int64)
    var beaten = 0
    echo "sentinel threshold sweep — mean seat score over seeds ", Seeds,
      ", ", Weeks, " weeks, all six seats on the cell"
    echo "  own\\road | " & Scales.mapIt(align($it, 9)).join(" ")
    for own in Scales:
      var row = "  " & align($own, 8) & " | "
      for road in Scales:
        let outcome = sweep(Thresholds(own: own, road: road))
        row.add(align($outcome.score, 9) & " ")
        if own == Ppm and road == Ppm:
          shippedScore = outcome.score
        if outcome.score > bestScore:
          bestScore = outcome.score
          bestOwn = own
          bestRoad = road
      echo row
    for own in Scales:
      for road in Scales:
        if own == Ppm and road == Ppm:
          continue
        if sweep(Thresholds(own: own, road: road)).score > shippedScore:
          inc beaten
    echo "  best cell own x", bestOwn, " road x", bestRoad, " score ",
      bestScore, " | shipped score ", shippedScore, " | cells that beat it ",
      beaten, "/", Scales.len * Scales.len - 1
    ## The shipped point is the argmax, and the optimum is INTERIOR in both
    ## dimensions — a best cell on the grid edge would mean the sweep had not
    ## converged and the shipped numbers were only the tightest thing tried.
    check bestOwn == Ppm
    check bestRoad == Ppm
    check beaten == 0

  test "reacting far too late is far worse, on every seed":
    ## The sweep's own sanity check: the surface has to have a gradient, or
    ## the grid above is measuring noise.
    let shipped = Thresholds(own: Ppm, road: Ppm)
    let late = Thresholds(own: 4 * Ppm, road: 4 * Ppm)
    for seed in Seeds:
      let good = playTuned(seed, shipped)
      let bad = playTuned(seed, late)
      check bad.deaths > good.deaths
      check bad.score < good.score
