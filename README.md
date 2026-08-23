# Contagion

**Six governors, one epidemic, nine roads.** Six LLM-piloted governors each run one region of a
six-node road network for twenty weeks. Every week each governor sets three dials — **lockdown**,
**testing** and one **border gate** per road — talks to the table, and may wire **aid** to any other
region. The infection then crosses the roads whether or not the road was closed, the economy pays
for the dials and for the sickness, and the dead are counted.

```
score(seat) = your region's accumulated GDP − 2 × your cumulative deaths
```

Higher is better and it can be negative: an uncontrolled epidemic loses more to the death penalty
than the region ever earned. Your neighbour's looseness is your problem.

Live at [softmax.com/contagion](https://softmax.com/contagion).

## The map

Six regions of 1,000,000 people each — Harborlea, Kestrel Flats, Riverbend, Ash Hollow, Wintermoor,
Saltmarch — on the 6-cycle plus its three long diagonals. Nine roads; every region has exactly two
main roads and one back road, so every governor's structural situation is byte-for-byte identical
and no seat is stuck anywhere. What differs is where the outbreak started (seeded) and what the
other five governors do.

Seat → region is a fresh seeded permutation every episode. Governors know regions, never players.

## The rules, in one screen

Every week, **simultaneously**, each governor submits:

| dial | range | what it does |
|---|---|---|
| `lockdown` | 0..4 | transmission 1.15 → 0.22; output factor 1.00 → 0.40 |
| `testing` | 0..3 | detection 15% → 90%; transmission ×1.00 → ×0.64; costs 0 → 110 a week |
| `borders` | 0..2 per road | pass-through 1.00 / 0.40 / 0.00 — **before** the leak |
| `aid` | ≤3 transfers, ≤200/week | settles immediately and unconditionally; no escrow, no enforcement |
| `say` | ≤160 runes | read by all six governors, one week late, non-binding |

Then the week resolves, in this exact order: dials latch (a road's **effective** gate is the
**tighter** of its two ends) → talk queues → aid settles → the infection crosses every road → the
economy pays → the dead are counted → the reports go out.

**Every road leaks.** A road sealed at both ends still passes **12%** of its traffic. Closure buys
time, never safety — and a road you shut costs the region at the far end money too.

**You never see the truth.** Not even your own: you see *reported* cases, which are your detection
rate times reality. At testing 0 that is 15% of the truth. Every region's testing level is public,
so any governor can de-bias any other region's number — that inference is intended play, not a leak.

All arithmetic is integer parts-per-million with truncating division. That is load-bearing: the
wasm replay viewer re-runs the same Nim rules in your browser and its re-derivation is checked
field-for-field against the recorded weeks.

## A policy is just a prompt

Every decision is made by Claude acting on a per-seat policy prompt. Field your own by reusing the
published player runnable and setting `PLAYER_PROMPT`:

```bash
coworld upload-policy coworld-contagion:latest \
  --name my-contagion --run /bin/contagion-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

All six seats' requests go out as **one parallel batch per week**, so an episode is twenty round
trips, not one hundred and twenty. A reply that does not parse is retried once with a hint, bounded
by what is left of the week's budget, and then falls back to the scripted `sentinel` move — an
episode always completes.

Two scripted baselines ship in the same image, selected with `PLAYER_SCRIPTED`:

- **`sentinel`** — the threshold dial policy: de-bias your own reported cases, step lockdown and
  testing at fixed prevalence thresholds, and gate each road against its neighbour's de-biased
  estimate. Also the universal fallback move.
- **`laggard`** — the leaky neighbour: testing always 0 (so it under-reports by 6.7× and never
  isolates), gates always open, and lockdown 3 for exactly three weeks once its own blind estimate
  finally crosses 4%. Late, blind and expensive for everyone downwind.

With no LLM credentials at all every seat plays `sentinel` and the episode still completes — that is
the offline-certification path and it is load-bearing.

## Watching it

The replay is a **static wasm bundle**: the browser re-derives every frame from the replay bytes and
contacts nothing but S3 for the `.replay` file. The outbreak is a red stain washing across each
region's tile; lockdown is 0–4 wooden shutters slamming down; testing is a lantern whose glow is
literally how far into that region you can see; aid arcs as gold packets; and each road carries a
crawling red seep whose thickness is the imported case count — a shut road still seeping is the
single most important picture in the game. Under the map, six curves of *true* infections against
the hospital-capacity line, with each region's *reported* curve dotted underneath.

## Repo layout

```
src/contagion/{types,sim,llm,server}.nim   the rules, the LLM batch, the mummy server
src/contagion.nim  src/contagion_player.nim  the two entrypoints in one image
client/                                    renderer.js + chrome.css + the three pages
replay-viewer/                             the wasm entry, its link flags and the static shell
tools/build_replay_viewer.sh               the `coworld build` hook (mode 100755)
tools/ci/                                  docker_smoke.sh, viewer_smoke.mjs, policies.json
tests/                                     sim, baselines, replay bytes, packaging invariants
scripts/art/                               the recipes for the committed art
```

## Development

The rules are pure and have no IO, so the tests run with nothing but Nim:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --path:src tests/test_sim.nim
```

CI runs every `tests/*.nim` twice (debug and `-d:release`), builds the production image and plays a
real six-seat episode in raw Docker, then builds the wasm bundle and **opens it in headless
chromium against the replay that episode produced**.

MIT licensed. Art: the governor portraits derive from the MIT-licensed coworld-ctf sprites
(`scripts/art/recolor_sprite.py`); the map plate and props are generated by
`scripts/art/make_props.py`.
